// Intent verbs (2.0 Batch D, plans/0.10-intent-surface.md): `uses`, `change`,
// `health`. Each COMPOSES the low-level verbs' internals (query/callers/
// impact/attention) instead of reimplementing extraction or rendering - the
// low-level verbs keep working unchanged. `review` and `plan` are pure
// dispatch aliases (bin/codegraph.dart routes them to diff/blueprint).
import 'dart:io';

import 'attention.dart' show renderAttention;
import 'callers.dart' as callers;
import 'cli_util.dart';
import 'freshness.dart';
import 'impact.dart' as impact;
import 'model.dart';
import 'query.dart' as query;
import 'resolve.dart';

/// Supertype name of a subtype edge: the typed field (format 6+), else the
/// pre-format-6 `'child -> parent'` detail text - the same fallback `impls`
/// uses.
String? _parentOf(GraphEdge e) {
  if (e.parentName != null) return e.parentName;
  final detail = e.detail ?? '';
  final arrow = detail.indexOf(' -> ');
  return arrow < 0 ? null : detail.substring(arrow + 4);
}

bool _isClassSymbol(Graph g, String name) => g.nodes.any((n) =>
    n.isFile && n.symbols.any((s) => s.kind == 'class' && s.name == name));

bool _hasSubtypeEdges(Graph g, String name) =>
    g.edges.any((e) => e.rel == 'implements/extends' && _parentOf(e) == name);

/// Callable declarations: a top-level function or any class/mixin/extension
/// member with this exact name.
bool _hasCallableDecl(Graph g, String name) {
  for (final n in g.nodes) {
    if (!n.isFile) continue;
    for (final s in n.symbols) {
      if (s.kind == 'fn' && s.name == name) return true;
    }
  }
  return query.findMemberHits(g, name.toLowerCase()).isNotEmpty;
}

/// `codegraph uses <thing>` - every INBOUND relation, sections picked by what
/// <thing> resolves to: provider -> readers; type/class -> subtype tree;
/// callable -> call sites; file -> inbound wiring. Strongest match renders,
/// other matching interpretations get a one-line pointer.
int runUses(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 80;
  if (positional.length < 2) {
    stderr.writeln('usage: uses <thing>');
    return 64;
  }
  final thing = positional[1];
  final graph = loadFresh();
  if (graph == null) return 66;

  final name = thing.replaceFirst('provider:', '');
  final isProvider = graph.nodes.any((n) => n.isProvider && n.name == name);
  final isType = _hasSubtypeEdges(graph, thing) || _isClassSymbol(graph, thing);

  if (isProvider) {
    query.readers(graph, [name], budget, false);
    if (isType) {
      stdout.writeln('also a class - see: codegraph impls $thing');
    }
    emitCaveats('uses');
    return 0;
  }
  if (isType) {
    query.impls(graph, [thing], budget, false);
    if (_hasCallableDecl(graph, thing)) {
      stdout.writeln('also callable - see: codegraph callers $thing');
    }
    emitCaveats('uses');
    return 0;
  }
  if (graph.declarationsOf(thing).isNotEmpty) {
    // callers' own AST scan; refs covers tear-offs/type uses - point there
    // instead of double-scanning.
    final code =
        callers.run(['callers', thing, '--budget', '$budget'], caveat: false);
    stdout.writeln('tear-offs/type/case uses: codegraph refs $thing');
    emitCaveats('uses');
    return code;
  }
  switch (resolveFileArg(graph, thing)) {
    case AmbiguousFile(:final candidates):
      printAmbiguous(thing, candidates, cap: budget);
      return 2;
    case ResolvedFile(:final path):
      _usesFile(graph, path, budget);
      emitCaveats('uses');
      return 0;
    case NotFoundFile():
      stdout.writeln('nothing in the graph matches "$thing" '
          '(${freshnessClause(graph.stats['files'] ?? 0)}) - try: '
          'codegraph find $thing');
      emitCaveats('uses');
      return 0;
  }
}

/// `codegraph change <thing>` - the pre-change pack: (1) dependents (impact's
/// depth-2 computation), (2) the subtype tree of the related Notifier/class
/// plus the state-type follow-up, (3) affected files with zero test refs.
/// Kills the canonical agent failure: renaming a provider and missing its
/// Notifier subclasses.
int runChange(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 80;
  if (positional.length < 2) {
    stderr.writeln('usage: change <thing>');
    return 64;
  }
  final thing = positional[1];
  final graph = loadFresh();
  if (graph == null) return 66;

  // Seed resolution mirrors impact's (provider name first, then file), with
  // one extension: a bare class/type name seeds from its declaring file(s).
  final providerDecls =
      graph.nodes.where((n) => n.isProvider && n.name == thing).toList();
  String? className;
  final Set<String> seed;
  if (providerDecls.isNotEmpty) {
    seed = providerDecls.map((n) => n.id).toSet();
  } else if (_isClassSymbol(graph, thing) || _hasSubtypeEdges(graph, thing)) {
    className = thing;
    seed = {
      for (final n in graph.nodes)
        if (n.isFile && n.symbols.any((s) => s.name == thing)) n.id,
    };
  } else {
    switch (resolveFileArg(graph, thing)) {
      case NotFoundFile():
        stdout.writeln('no match '
            '(${freshnessClause(graph.stats['files'] ?? 0)}) - try: '
            'codegraph find $thing');
        return 1;
      case AmbiguousFile(:final candidates):
        printAmbiguous(thing, candidates, cap: budget);
        return 2;
      case ResolvedFile(:final path):
        seed = {'file:$path'};
    }
  }

  stdout.writeln('change $thing - pre-change pack');
  stdout.writeln('');

  // 1. dependents - impact's computation and rendering at depth 2.
  final levels = impact.impactLevels(graph, seed, 2);
  emit(impact.renderImpactLines(graph, thing, 2, levels), budget,
      hint: 'raise --budget N');
  stdout.writeln('');

  // 2. subtype tree. For a Notifier-backed provider this is the expanded
  // _shapeChangeHint: the ACTUAL impls tree of the Notifier class instead of
  // a pointer. State-type users are content tokens, not graph edges - never
  // guess; print the exact follow-up command instead.
  if (providerDecls.isNotEmpty) {
    final info = query.notifierInfo(graph, providerDecls);
    if (info == null) {
      stdout.writeln(
          'subtype tree: $thing is ${providerDecls.first.providerType}-backed '
          '- no Notifier class to expand');
    } else if (info.notifierClass == null) {
      stdout.writeln('subtype tree: Notifier class not parsed from '
          '${info.decl.declaredIn} - read the file, then: '
          'codegraph impls <Notifier>');
    } else {
      query.impls(graph, [info.notifierClass!], budget, false);
    }
    if (info?.stateType != null) {
      stdout
          .writeln('state-type users: run: codegraph refs ${info!.stateType}');
    }
  } else if (className != null) {
    query.impls(graph, [className], budget, false);
  }

  // 3. test coverage of the blast radius (candidate data - see caveat).
  final untested = levels
      .expand((ns) => ns)
      .where((n) => n.testRefs == 0 && untestedRoles.contains(n.role))
      .toList();
  if (providerDecls.isNotEmpty || className != null) stdout.writeln('');
  stdout.writeln('untested in blast radius (${untested.length}):');
  if (untested.isEmpty) {
    stdout.writeln('  (none - every affected file has test references)');
  } else {
    emit(
      untested
          .map((n) => '  ${n.id.replaceFirst('file:', '')}  [${n.role}]')
          .toList(),
      budget,
    );
  }
  emitCaveats('change');
  return 0;
}

/// `codegraph health` - repo triage in one budgeted card: attention's
/// deterministic sections (reused, never recomputed differently) followed by
/// unused and untested summaries (counts + top 10 each).
int runHealth(List<String> args) {
  final graph = loadFresh();
  if (graph == null) return 66;
  // A bigger default than the per-verb 80: this card stacks three surfaces.
  final budget = intFlag(args, '--budget') ?? 150;

  final lines = renderAttention(graph).split('\n');
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  List<String> top10(List<String> items) => items.isEmpty
      ? ['  (none)']
      : [
          ...items.take(10),
          if (items.length > 10) '  … ${items.length - 10} more',
        ];

  final deadProviders = graph.unusedProviders;
  final orphans = graph.orphanFiles;
  final noTestProviders = query.untestedProviders(graph);
  final noTestFiles = query.untestedFiles(graph);
  String deg(GraphNode n) => inDegSuffix(graph.inDeg[n.id] ?? 0);
  lines
    ..add('')
    ..add('## Unused (dead-code candidates)')
    ..add('')
    ..add('providers with 0 lib consumers (${deadProviders.length}):')
    ..addAll(top10([
      for (final n in deadProviders)
        '  ${n.id.replaceFirst('provider:', '')} - ${n.providerType} - '
            '${n.declaredIn}${n.testOnlySuffix}',
    ]))
    ..add('files nothing imports (${orphans.length}):')
    ..addAll(top10([
      for (final n in orphans)
        '  ${n.id.replaceFirst('file:', '')}  [${n.role}]${n.testOnlySuffix}',
    ]))
    ..add('')
    ..add('## Untested (coverage-gap candidates)')
    ..add('')
    ..add('providers with zero test references (${noTestProviders.length}):')
    ..addAll(top10([
      for (final n in noTestProviders)
        '  ${n.name} - ${n.providerType} - ${n.declaredIn}${deg(n)}',
    ]))
    ..add('files with zero test references (${noTestFiles.length}):')
    ..addAll(top10([
      for (final n in noTestFiles)
        '  ${n.id.replaceFirst('file:', '')}  [${n.role}]${deg(n)}',
    ]));

  emit(lines, budget, hint: 'raise --budget N');
  emitCaveats('health');
  return 0;
}

/// Inbound wiring of one file: importers, navigations landing here, and the
/// readers of every provider it declares (the file case of `uses`).
void _usesFile(Graph graph, String path, int budget) {
  final id = 'file:$path';
  final record = query.wiringRecord(graph, id);
  final importers = record['imported-by']!;
  final navHere = graph.edges
      .where((e) => e.rel == 'navigates-to' && e.dst == id)
      .map((e) => e.src.replaceFirst('file:', ''))
      .toSet()
      .toList()
    ..sort();
  final declared = graph.edges
      .where((e) => e.src == id && e.rel == 'declares')
      .map((e) => graph.byId[e.dst])
      .whereType<GraphNode>()
      .toList()
    ..sort((a, b) => a.id.compareTo(b.id));

  final out = <String>[
    '$path  [${graph.byId[id]?.role}] - inbound wiring',
  ];
  if (importers.isNotEmpty) {
    out.add('imported-by (${importers.length}):');
    out.addAll(importers.map((f) => '  $f'));
  }
  if (navHere.isNotEmpty) {
    out.add('navigated-to from (${navHere.length}):');
    out.addAll(navHere.map((f) => '  $f'));
  }
  for (final p in declared) {
    out.add('');
    query.readersInto(graph, out, p);
  }
  if (importers.isEmpty && navHere.isEmpty && declared.isEmpty) {
    out.add('  (no inbound wiring - '
        '${freshnessClause(graph.stats['files'] ?? 0)})');
  }
  emit(out, budget, hint: 'raise --budget N');
}
