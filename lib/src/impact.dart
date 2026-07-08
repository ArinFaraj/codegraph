// `codegraph impact <thing> [--depth N]` — transitive dependents: what
// breaks if `<thing>` changes. Same resolve UX as `wiring`/`skeleton`/`path`
// (exact provider name, else unique file substring), then BFS outward over
// the reverse of imports/watches/reads/listens/declares.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'model.dart';

/// One BFS step: file ids that directly depend on any id in [nodeIds].
/// A file F depends on X if:
///  (a) F --imports--> X, X a file;
///  (b) F --watches/reads/listens--> X, X a provider;
///  (c) X is a file and F watches/reads/listens a provider declared in X
///      (F -> p, X --declares--> p).
///
/// Reverse indexes are precomputed once per call so repeated levels don't
/// rescan `graph.edges`. Pure over [Graph] — exported for Stage 3 (`diff`'s
/// blast-radius section) to reuse.
Set<String> dependentsOf(Graph g, Set<String> nodeIds) {
  // dst -> readers (src), for imports/watches/reads/listens.
  final readersOf = <String, List<String>>{};
  // declaring file -> provider ids it declares.
  final declaredBy = <String, List<String>>{};
  for (final e in g.edges) {
    switch (e.rel) {
      case 'imports':
      case 'watches':
      case 'reads':
      case 'listens':
        readersOf.putIfAbsent(e.dst, () => []).add(e.src);
      case 'declares':
        declaredBy.putIfAbsent(e.src, () => []).add(e.dst);
    }
  }

  final out = <String>{};
  for (final id in nodeIds) {
    // (a) + (b): direct readers of this id (file or provider).
    out.addAll(readersOf[id] ?? const []);
    // (c): id is a file — pull in readers of every provider it declares.
    for (final p in declaredBy[id] ?? const []) {
      out.addAll(readersOf[p] ?? const []);
    }
  }
  return out;
}

/// Resolves `arg` to a seed node-id set exactly like `wiring`/`skeleton`:
/// 1. exact provider name (ALL declarations when ambiguous — union readers);
/// 2. unique file substring (exact-suffix tiebreak, else ambiguous list);
/// else null (caller prints the `find` hint).
Set<String>? _resolveSeed(Graph graph, String arg, int budget) {
  final providerDecls =
      graph.nodes.where((n) => n.isProvider && n.name == arg).toList();
  if (providerDecls.isNotEmpty) {
    return providerDecls.map((n) => n.id).toSet();
  }

  final hits = graph.nodes
      .where((n) => n.isFile && n.id.contains(arg))
      .map((n) => n.id)
      .toList();
  if (hits.length == 1) return {hits.first};
  final exact = hits.where((h) => h.endsWith('/$arg') || h.endsWith(':$arg'));
  if (exact.length == 1) return {exact.first};
  if (hits.length > 1) {
    stdout.writeln('"$arg" is ambiguous (${hits.length} files):');
    for (final h in hits.take(budget)) {
      stdout.writeln('  ${h.replaceFirst('file:', '')}');
    }
    return null;
  }
  return null;
}

String _renderFile(Graph g, GraphNode n) {
  final bare = n.id.replaceFirst('file:', '');
  final role = n.role == 'view' ? ' [view]' : '';
  return '  $bare$role${inDegSuffix(g.inDeg[n.id] ?? 0)}';
}

/// `int run(List<String> args)` — `impact <thing> [--depth N] [--json]
/// [--budget N]`.
int run(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  var depth = intFlag(args, '--depth') ?? 2;

  if (positional.length < 2) {
    stderr.writeln('usage: impact <thing> [--depth N]');
    return 64;
  }
  final arg = positional[1];

  final graph = Graph.load();
  if (graph == null) return 66;

  String? depthWarning;
  final requestedDepth = depth;
  if (depth > 5) {
    depthWarning = 'depth $depth capped at 5';
    depth = 5;
  }

  final seed = _resolveSeed(graph, arg, budget);
  if (seed == null) {
    if (!asJson) stdout.writeln('no match — try: find $arg');
    return 1;
  }

  // Level 1..N: level k = dependentsOf(level k-1 FILES) minus everything
  // already seen. Providers only participate at the seed (level-0) step.
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

  final levelNodes = levels
      .map((ids) => ids.map((id) => graph.byId[id]).whereType<GraphNode>())
      .toList();
  final allFiles = levelNodes.expand((ns) => ns).toList();
  final pages = allFiles.where((n) => n.role == 'view').length;

  int Function(GraphNode, GraphNode) byDegThenName() => (a, b) {
        final byDeg =
            (graph.inDeg[b.id] ?? 0).compareTo(graph.inDeg[a.id] ?? 0);
        return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
      };
  final sortedLevels =
      levelNodes.map((ns) => ns.toList()..sort(byDegThenName())).toList();

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
        'verb': 'impact',
        'query': arg,
        'depth': depth,
        if (depthWarning != null) 'requestedDepth': requestedDepth,
        'summary': {'files': allFiles.length, 'pages': pages},
        'levels': jsonLevels,
        if (truncatedAny) 'truncated': true,
      }),
    );
    return 0;
  }

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
  emit(out, budget, hint: 'raise --budget N');
  return 0;
}
