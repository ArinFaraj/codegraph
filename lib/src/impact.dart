// `codegraph impact <thing> [--depth N]` — transitive dependents: what
// breaks if `<thing>` changes. Same resolve UX as `wiring`/`skeleton`/`path`
// (exact provider name, else unique file substring), then BFS outward over
// the reverse of imports/provider interactions/declares.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'freshness.dart';
import 'model.dart';
import 'resolve.dart';

/// One BFS step: file ids that directly depend on any id in [nodeIds].
/// A file F depends on X if:
///  (a) F --imports--> X, X a file;
///  (b) F --provider interaction--> X, X a provider;
///  (c) X is a file and F interacts with a provider declared in X
///      (F -> p, X --declares--> p);
///  (d) resolved typed-route dependencies (caller -> route -> page/parent/
///      redirect target), crossing non-file route ids within one BFS step.
///
/// Reverse indexes are precomputed once per call so repeated levels don't
/// rescan `graph.edges`. Pure over [Graph] — exported for Stage 3 (`diff`'s
/// blast-radius section) to reuse.
Set<String> dependentsOf(Graph g, Set<String> nodeIds) {
  // dst -> readers/interactors (src), including resolved route dependencies.
  final readersOf = <String, List<String>>{};
  // declaring file -> provider ids it declares.
  final declaredBy = <String, List<String>>{};
  for (final e in g.edges) {
    switch (e.rel) {
      case 'imports':
      case 'watches':
      case 'reads':
      case 'listens':
      case 'invalidates':
      case 'refreshes':
      case 'navigates':
      case 'builds':
      case 'redirects-to':
      case 'nested-under':
      case 'branch-of':
      case 'in-branch':
      case 'in-shell':
        readersOf.putIfAbsent(e.dst, () => []).add(e.src);
      case 'declares':
      case 'declares-route':
        declaredBy.putIfAbsent(e.src, () => []).add(e.dst);
    }
  }

  final out = <String>{};
  final virtualQueue = <String>[...nodeIds];
  final seenVirtual = <String>{};
  while (virtualQueue.isNotEmpty) {
    final id = virtualQueue.removeLast();
    if (!seenVirtual.add(id)) continue;
    for (final declared in declaredBy[id] ?? const []) {
      virtualQueue.add(declared);
    }
    for (final reader in readersOf[id] ?? const []) {
      if (reader.startsWith('file:')) {
        if (!nodeIds.contains(reader)) out.add(reader);
      } else {
        virtualQueue.add(reader);
      }
    }
  }
  return out;
}

String _renderFile(Graph g, GraphNode n) {
  final bare = n.id.replaceFirst('file:', '');
  final role = n.role == 'view' ? ' [view]' : '';
  return '  $bare$role${inDegSuffix(g.inDeg[n.id] ?? 0)}';
}

/// Level-by-level dependents BFS from [seed] (providers participate only at
/// the seed step; deeper levels are files), each level sorted in-degree desc
/// then name. Shared by `impact` and `change` (intent.dart).
List<List<GraphNode>> impactLevels(Graph graph, Set<String> seed, int depth) {
  final seen = <String>{...seed};
  final levels = <List<String>>[];
  var frontier = seed;
  for (var k = 1; k <= depth; k++) {
    final next = dependentsOf(graph, frontier)
        .where((id) => id.startsWith('file:') && !seen.contains(id))
        .toSet();
    if (next.isEmpty) break;
    seen.addAll(next);
    levels.add(next.toList());
    frontier = next;
  }
  int byDegThenName(GraphNode a, GraphNode b) {
    final byDeg = (graph.inDeg[b.id] ?? 0).compareTo(graph.inDeg[a.id] ?? 0);
    return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
  }

  return levels
      .map((ids) =>
          ids.map((id) => graph.byId[id]).whereType<GraphNode>().toList()
            ..sort(byDegThenName))
      .toList();
}

/// The impact card's text lines (header + affected counts + per-level top
/// 15) - shared by `impact`'s text mode and `change`'s dependents section.
List<String> renderImpactLines(
  Graph graph,
  String arg,
  int depth,
  List<List<GraphNode>> sortedLevels, {
  String? depthWarning,
}) {
  final allFiles = sortedLevels.expand((ns) => ns).toList();
  final pages = allFiles.where((n) => n.role == 'view').length;
  final out = <String>['impact of $arg  (depth $depth)'];
  if (depthWarning != null) out.add(depthWarning);
  out.add('affected: ${allFiles.length} files ($pages pages) at depth<=$depth');
  for (var i = 0; i < sortedLevels.length; i++) {
    final ns = sortedLevels[i];
    out.add('');
    out.add('depth ${i + 1} (${ns.length}):');
    out.addAll(ns.take(15).map((n) => _renderFile(graph, n)));
    if (ns.length > 15) out.add('  … ${ns.length - 15} more');
  }
  return out;
}

/// `int run(List<String> args)` — `impact <thing> [--depth N] [--json]
/// [--budget N]`.
int run(List<String> args) {
  final positional = positionalArgs(args);
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  var depth = intFlag(args, '--depth') ?? 2;

  if (positional.length < 2) {
    stderr.writeln('usage: impact <thing> [--depth N]');
    return 64;
  }
  final arg = positional[1];

  final graph = loadFresh();
  if (graph == null) return 66;

  String? depthWarning;
  final requestedDepth = depth;
  if (depth > 5) {
    depthWarning = 'depth $depth capped at 5';
    depth = 5;
  }

  // Seed resolution: exact provider name first (ALL declarations when
  // ambiguous - union readers), else the shared file resolver (same
  // semantics as wiring/skeleton/path/brief).
  final providerDecls =
      graph.nodes.where((n) => n.isProvider && n.name == arg).toList();
  final Set<String> seed;
  if (providerDecls.isNotEmpty) {
    seed = providerDecls.map((n) => n.id).toSet();
  } else {
    switch (resolveFileArg(graph, arg)) {
      case NotFoundFile():
        if (!asJson) {
          stdout.writeln('no match '
              '(${freshnessClause(graph.stats['files'] ?? 0)}) — '
              'try: find $arg');
        }
        return 1;
      case AmbiguousFile(:final candidates):
        printAmbiguous(arg, candidates, cap: budget);
        return 2;
      case ResolvedFile(:final path):
        seed = {'file:$path'};
    }
  }

  // Level 1..N: level k = dependentsOf(level k-1 FILES) minus everything
  // already seen. Providers only participate at the seed (level-0) step.
  final sortedLevels = impactLevels(graph, seed, depth);
  final allFiles = sortedLevels.expand((ns) => ns).toList();
  final pages = allFiles.where((n) => n.role == 'view').length;

  if (asJson) {
    // Each level capped INDEPENDENTLY at `budget` — not via one shared Budget
    // consumed across levels, which starved deeper levels to [] once level 1
    // used it up (so `summary.files` said 306 while `levels` listed ~80; found
    // by an A/B eval). `truncated` set if any level exceeded its cap.
    var truncatedAny = false;
    final jsonLevels = sortedLevels.map(
      (ns) {
        if (ns.length > budget) truncatedAny = true;
        return ns
            .take(budget)
            .map((n) => {
                  'file': n.id.replaceFirst('file:', ''),
                  'role': n.role,
                  'inDeg': graph.inDeg[n.id] ?? 0,
                })
            .toList();
      },
    ).toList();
    stdout.writeln(
      jsonEncode({
        ...envelope('impact', arg),
        'depth': depth,
        if (depthWarning != null) 'requestedDepth': requestedDepth,
        'summary': {'files': allFiles.length, 'pages': pages},
        'levels': jsonLevels,
        if (truncatedAny) 'truncated': true,
      }),
    );
    return 0;
  }

  final out = renderImpactLines(graph, arg, depth, sortedLevels,
      depthWarning: depthWarning);
  emit(out, budget, hint: 'raise --budget N');
  emitCaveats('impact');
  return 0;
}
