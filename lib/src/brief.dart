// `codegraph brief <thing>` and `codegraph passport` — one-shot context
// cards composed entirely from the loaded graph (no source-file reads).
//
// brief resolves its single argument to a provider, an area, a file, or a
// symbol (in that order — most-specific-first so a name that happens to
// match multiple kinds resolves to the most useful card) and prints a
// compact card. passport prints a deterministic session digest. Both share
// `Graph.load()` rather than re-implementing the load.
import 'dart:io';

import 'cli_util.dart';
import 'init.dart' show scaffoldVersion, hasClaudeBeginLine;
import 'freshness.dart';
import 'model.dart';
import 'query.dart' show findMemberHits;
import 'resolve.dart';
import 'version_skew.dart';

/// `int run(List<String> args)` — dispatches `brief <thing>` (args[0] ==
/// 'brief') and `passport` (args[0] == 'passport').
int run(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 150;

  if (positional.first == 'passport') {
    return _passport();
  }

  if (positional.length < 2) {
    stderr.writeln('usage: brief <provider|area|file|symbol>');
    return 64;
  }
  final graph = loadFresh();
  if (graph == null) return 66;
  return _brief(graph, positional[1], budget);
}

// ---------------------------------------------------------------------------
// brief

int _brief(Graph graph, String arg, int budget) {
  // 1. exact provider name match.
  final providerDecls = graph.nodes
      .where((n) => n.isProvider && n.name == arg)
      .toList()
    ..sort((a, b) => a.declaredIn!.compareTo(b.declaredIn!));
  if (providerDecls.isNotEmpty) {
    emit(_providerBrief(graph, providerDecls), budget,
        hint: 'raise --budget N');
    return 0;
  }

  // 2. area prefix: `lib/<x>`, `packages/<x>`, or a bare area name with >=2
  // files under lib/<arg>/ or packages/<arg>/.
  final areaPrefix = _resolveArea(graph, arg);
  if (areaPrefix != null) {
    emit(_areaBrief(graph, areaPrefix), budget, hint: 'raise --budget N');
    return 0;
  }

  // 3. file-substring match via the shared resolver (unique substring, else
  // exact-suffix tiebreak). An ambiguous hit does NOT refuse yet - the arg
  // may still name a symbol or member below; the refusal only fires when
  // every later stage also misses.
  final fileRes = resolveFileArg(graph, arg);
  if (fileRes is ResolvedFile) {
    final node = graph.byId['file:${fileRes.path}'];
    if (node != null) {
      emit(_fileBrief(graph, node), budget, hint: 'raise --budget N');
      return 0;
    }
  }

  // 4. exact symbol name match -> FILE brief of the defining file, symbol
  // card on top.
  final lower = arg.toLowerCase();
  for (final n in graph.nodes) {
    if (!n.isFile) continue;
    for (final s in n.symbols) {
      if (s.name.toLowerCase() == lower) {
        final out = _symCard(n, s);
        out.add('');
        out.addAll(_fileBrief(graph, n, skipSymbols: true));
        emit(out, budget, hint: 'raise --budget N');
        return 0;
      }
    }
  }

  // 5. no top-level symbol either — fall back to class/mixin/extension
  // MEMBERS (same fallback `sym` uses) so `brief m13`/`brief render` resolve
  // instead of giving up.
  final memberHits = findMemberHits(graph, lower);
  if (memberHits.isNotEmpty) {
    final out = <String>[];
    for (final h in memberHits.take(10)) {
      out.add('member: ${h.owner}.${h.name}  —  ${h.file}:${h.line}');
      out.add('  ${h.sig}');
    }
    if (memberHits.length > 10) out.add('… ${memberHits.length - 10} more');
    out.add('(run `callers $arg` for call sites)');
    emit(out, budget, hint: 'raise --budget N');
    return 0;
  }

  // Nothing else matched; if the file stage saw multiple candidates, that
  // ambiguity is the real answer (exit 2, the cannot-answer code).
  if (fileRes is AmbiguousFile) {
    printAmbiguous(arg, fileRes.candidates);
    return 2;
  }

  stdout.writeln('no match '
      '(${freshnessClause(graph.stats['files'] ?? 0)}) — try: find $arg');
  return 1;
}

/// Resolves `arg` to a canonical area prefix (`lib/<x>/` or `packages/<x>/`)
/// when it names an area with >=2 files, else null. Accepts `lib/<x>`,
/// `packages/<x>`, or a bare `<x>` (tried under both roots).
String? _resolveArea(Graph graph, String arg) {
  String norm(String s) => s.endsWith('/') ? s : '$s/';
  bool has(String prefix) =>
      graph.nodes.any((n) => n.isFile && n.id.startsWith('file:$prefix'));
  int count(String prefix) => graph.nodes
      .where((n) => n.isFile && n.id.startsWith('file:$prefix'))
      .length;

  final candidates = <String>[];
  if (arg.startsWith('lib/') || arg.startsWith('packages/')) {
    candidates.add(norm(arg));
  } else {
    candidates
      ..add(norm('lib/$arg'))
      ..add(norm('packages/$arg'));
  }
  for (final c in candidates) {
    if (has(c) && count(c) >= 2) return c;
  }
  return null;
}

List<String> _symCard(GraphNode file, SymbolRec s) {
  final barePath = bare(file.id);
  final out = <String>[
    '${s.name}  ${s.kind}  $barePath:${s.line}',
    '  ${s.sig}',
  ];
  if (s.doc != null) out.add('  ${s.doc}');
  final members = s.members;
  if (members != null && members.isNotEmpty) {
    out.add('  members:');
    out.addAll(members.map((m) => '    $m'));
  }
  return out;
}

/// FILE brief: symbols inline, both-direction wiring with per-neighbor
/// in-degree, readers of each declared provider. [skipSymbols] is used by
/// the symbol-hit path (4), which already printed that symbol's card above.
List<String> _fileBrief(
  Graph graph,
  GraphNode file, {
  bool skipSymbols = false,
  bool skipProviderSections = false,
}) {
  final id = file.id;
  final barePath = bare(id);
  final role = file.role;
  final deg = graph.inDeg[id] ?? 0;
  final out = <String>[
    '── $barePath${role != null ? '  [$role]' : ''}${deg > 0 ? '  ·$deg⇐' : ''}',
  ];

  final symbols = file.symbols;
  if (!skipSymbols) {
    out.add('symbols:');
    if (symbols.isEmpty) {
      out.add('  (none)');
    } else {
      for (final s in symbols) {
        final doc = s.doc != null ? ' — ${s.doc}' : '';
        out.add('  ${s.line}: ${s.sig}$doc');
        final members = s.members;
        if (members != null) {
          for (final m in members) {
            out.add('     $m');
          }
        }
      }
    }
  }

  List<String> section(String rel, {bool withLine = false}) {
    final items = graph.edges.where((e) => e.src == id && e.rel == rel).toList()
      ..sort((a, b) => a.dstDisplayName.compareTo(b.dstDisplayName));
    return items
        .map((e) =>
            withLine ? '${e.dstDisplayName}:${e.line}' : e.dstDisplayName)
        .toList();
  }

  final declares = graph.edges
      .where((e) => e.src == id && e.rel == 'declares')
      .toList()
    ..sort((a, b) => a.dstDisplayName.compareTo(b.dstDisplayName));
  if (!skipProviderSections) {
    out.add(
      declares.isEmpty
          ? 'declares: (none)'
          : 'declares (${declares.length}): '
              '${joinCapped(declares.map((e) => e.dstDisplayName).toList())}',
    );
  }

  for (final rel in ['watches', 'reads', 'listens']) {
    final list = section(rel, withLine: true);
    out.add(
      list.isEmpty
          ? '$rel: (none)'
          : '$rel (${list.length}): ${joinCapped(list)}',
    );
  }

  final navLines = graph.navLines(id);
  out.add(
    navLines.isEmpty
        ? 'navigates: (none)'
        : 'navigates (${navLines.length}): ${joinCapped(navLines)}',
  );

  final imports = graph.edges
      .where((e) => e.src == id && e.rel == 'imports')
      .toList()
    ..sort((a, b) => a.dst.compareTo(b.dst));
  final importLines = imports.map((e) {
    final dst = e.dst;
    return '${dst.replaceFirst('file:', '')}${inDegSuffix(graph.inDeg[dst] ?? 0)}';
  }).toList();
  out.add(
    importLines.isEmpty
        ? 'imports: (none)'
        : 'imports (${importLines.length}): ${joinCapped(importLines)}',
  );

  final importedBy = graph.edges
      .where((e) => e.dst == id && e.rel == 'imports')
      .map((e) => e.src.replaceFirst('file:', ''))
      .toList()
    ..sort();
  out.add(
    importedBy.isEmpty
        ? 'imported-by: (none)'
        : 'imported-by (${importedBy.length}): ${joinCapped(importedBy)}',
  );

  // Readers of each provider this file declares — compact per-provider line.
  if (!skipProviderSections) {
    if (declares.isEmpty) {
      out.add('readers of declared providers: (none)');
    } else {
      out.add('readers of declared providers:');
      for (final d in declares) {
        final dstId = d.dst;
        final name = d.dstDisplayName;
        final readers = graph.edges
            .where(
              (e) => e.dst == dstId && providerConsumerRels.contains(e.rel),
            )
            .map((e) => e.src.replaceFirst('file:', ''))
            .toSet()
            .toList()
          ..sort();
        out.add(
          readers.isEmpty
              ? '  $name: (no readers)'
              : '  $name (${readers.length}): ${joinCapped(readers)}',
        );
      }
    }
  }

  final noteName = _fileNoteName(barePath);
  if (noteName != null && File('docs/maps/notes/$noteName.md').existsSync()) {
    out.add('area notes exist: docs/maps/notes/$noteName.md');
  }

  return out;
}

/// Area note name for a bare file path (`lib/home/foo.dart` -> `home`,
/// `packages/design_system/lib/x.dart` -> `design_system`), or null when the file
/// isn't at least one directory deep under `lib/` or `packages/` (mirrors
/// passport's `areaOf`).
String? _fileNoteName(String barePath) {
  final segs = barePath.split('/');
  if (segs.length < 3) return null;
  return segs[1];
}

/// PROVIDER brief: readers output for every declaration of this name, plus
/// each declaring file's FILE brief with the provider list stripped (that
/// list is already shown above by the readers section).
List<String> _providerBrief(Graph graph, List<GraphNode> decls) {
  final out = <String>[];
  for (final decl in decls) {
    if (out.isNotEmpty) out.add('');
    final id = decl.id;
    final name = decl.name!;
    out.add(
      'provider $name — ${decl.providerType}'
      '${decl.autoDispose == true ? ' (autoDispose)' : ''}'
      ' — declared in ${decl.declaredIn}:${decl.line}',
    );
    final byRel = <String, List<String>>{};
    for (final rel in ['watches', 'reads', 'listens']) {
      final list = graph.edges
          .where((e) => e.dst == id && e.rel == rel)
          .map((e) => e.src.replaceFirst('file:', ''))
          .toList()
        ..sort();
      if (list.isNotEmpty) byRel[rel] = list;
    }
    if (byRel.isEmpty) {
      out.add('  (no readers)');
    } else {
      for (final rel in ['watches', 'reads', 'listens']) {
        final list = byRel[rel];
        if (list == null) continue;
        out.add('  $rel (${list.length}): ${joinCapped(list)}');
      }
    }

    // Declaring file's FILE brief, minus the "declares"/"readers of declared
    // providers" lines (already shown above) — drop those two lines.
    final fileNode = graph.byId['file:${decl.declaredIn}'];
    if (fileNode != null) {
      out.add('');
      out.addAll(_fileBrief(graph, fileNode, skipProviderSections: true));
    }
  }
  return out;
}

/// AREA brief: counts, entry pages, providers by reader
/// count, cross-area providers consumed, top files by in-degree, nav targets.
List<String> _areaBrief(Graph graph, String prefix) {
  final files = graph.nodes
      .where((n) => n.isFile && n.id.startsWith('file:$prefix'))
      .toList();
  final fileIds = files.map((f) => f.id).toSet();
  final providersDeclared = graph.nodes.where(
    (n) => n.isProvider && fileIds.contains('file:${n.declaredIn}'),
  );

  final areaName = prefix.substring(0, prefix.length - 1);
  final out = <String>[
    '── $areaName  (${files.length} files, ${providersDeclared.length} providers)',
  ];

  // entry pages: role=view with navigates.
  final entryPages = files
      .where(
        (f) =>
            f.role == 'view' &&
            graph.edges.any((e) => e.src == f.id && e.rel == 'navigates'),
      )
      .map((f) => f.id.replaceFirst('file:', ''))
      .toList()
    ..sort();
  out.add(
    entryPages.isEmpty
        ? 'entry pages: (none)'
        : 'entry pages (${entryPages.length}): '
            '${(entryPages.take(10).toList()..addAll(entryPages.length > 10 ? [
                '… ${entryPages.length - 10} more'
              ] : [])).join(', ')}',
  );

  // providers by reader count (top 10), sorted count desc then name.
  final readerCount = <String, int>{};
  for (final p in providersDeclared) {
    final id = p.id;
    final n = graph.edges
        .where(
          (e) => e.dst == id && providerConsumerRels.contains(e.rel),
        )
        .length;
    readerCount[p.name!] = n;
  }
  final rankedProviders = readerCount.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  out.add(
    rankedProviders.isEmpty
        ? 'providers by reader count: (none)'
        : 'providers by reader count: '
            '${rankedProviders.take(10).map((e) => '${e.key} ·${e.value}').join(', ')}'
            '${rankedProviders.length > 10 ? ', … ${rankedProviders.length - 10} more' : ''}',
  );

  // cross-area providers consumed: providers declared OUTSIDE this area but
  // watched/read/listened from inside it.
  final crossConsumed = <String, String>{}; // name -> declaredIn
  for (final f in files) {
    final id = f.id;
    for (final rel in ['watches', 'reads', 'listens']) {
      for (final e in graph.edges.where((e) => e.src == id && e.rel == rel)) {
        final dst = e.dst;
        if (!dst.startsWith('provider:')) continue;
        final declNode = graph.byId[dst];
        if (declNode == null || !declNode.isProvider) continue;
        final declaredIn = declNode.declaredIn!;
        if (!declaredIn.startsWith(prefix)) {
          crossConsumed[declNode.name!] = declaredIn;
        }
      }
    }
  }
  final crossKeys = crossConsumed.keys.toList()..sort();
  out.add(
    crossKeys.isEmpty
        ? 'cross-area providers consumed: (none)'
        : 'cross-area providers consumed (${crossKeys.length}): '
            '${crossKeys.take(10).map((k) => '$k ← ${crossConsumed[k]}').join(', ')}'
            '${crossKeys.length > 10 ? ', … ${crossKeys.length - 10} more' : ''}',
  );

  // top files by in-degree (top 10).
  final rankedFiles = files.toList()
    ..sort((a, b) {
      final byDeg = (graph.inDeg[b.id] ?? 0).compareTo(graph.inDeg[a.id] ?? 0);
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  out.add(
    rankedFiles.isEmpty
        ? 'top files by in-degree: (none)'
        : 'top files by in-degree: '
            '${rankedFiles.take(10).map((f) => '${f.id.replaceFirst('file:', '')} ·${graph.inDeg[f.id] ?? 0}⇐').join(', ')}',
  );

  // navigation targets (top 10), count desc then name.
  final navTargets = <String, int>{};
  for (final f in files) {
    for (final e
        in graph.edges.where((e) => e.src == f.id && e.rel == 'navigates')) {
      final target = e.dst.replaceFirst('route:', '');
      navTargets[target] = (navTargets[target] ?? 0) + 1;
    }
  }
  final rankedNav = navTargets.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  out.add(
    rankedNav.isEmpty
        ? 'navigation targets: (none)'
        : 'navigation targets: '
            '${rankedNav.take(10).map((e) => '${e.key} ·${e.value}').join(', ')}'
            '${rankedNav.length > 10 ? ', … ${rankedNav.length - 10} more' : ''}',
  );

  out.addAll(_notesSection(_areaNoteName(areaName)));

  return out;
}

/// Ungated knowledge sidecar: `docs/maps/notes/<area>.md`,
/// hand/agent-authored, never generated, never rewritten by build(). If it
/// exists, appended as a final area-brief section — first 20 lines, then a
/// `… N more lines` marker. Empty list when there's no note (nothing to add).
List<String> _notesSection(String noteName) {
  final path = 'docs/maps/notes/$noteName.md';
  final f = File(path);
  if (!f.existsSync()) return const [];
  final lines = f.readAsLinesSync();
  final out = <String>['notes ($path):'];
  out.addAll(lines.take(20));
  if (lines.length > 20) {
    out.add('… ${lines.length - 20} more lines — read the file');
  }
  return out;
}

/// bare area name (`onboarding`, `design_system`, …) — the last path segment of
/// `lib/<x>` or `packages/<x>` — same convention `docs/maps/notes/<name>.md`
/// uses.
String _areaNoteName(String areaPath) =>
    areaPath.substring(areaPath.lastIndexOf('/') + 1);

// ---------------------------------------------------------------------------
// passport

String _projectName() {
  final f = File('pubspec.yaml');
  if (!f.existsSync()) return '(unknown)';
  for (final line in f.readAsLinesSync()) {
    final m = RegExp(r'^name:\s*(\S+)').firstMatch(line);
    if (m != null) return m.group(1)!;
  }
  return '(unknown)';
}

int _passport() {
  // Skew nudge FIRST: it reads only scaffolding files (not the graph), and a
  // fresh/unbuilt host — exactly when Graph.load() bails — is when a stale
  // scaffold warning matters most. Printed here so the graph-absent path still
  // surfaces it; the graph-present path below does NOT re-print it.
  final nudge = _skewNudge();
  if (nudge != null) stdout.writeln(nudge);

  final graph = loadFresh();
  if (graph == null) return 66;
  final files = graph.nodes.where((n) => n.isFile).toList();
  final providers = graph.nodes.where((n) => n.isProvider).toList();
  final testFiles = graph.stats['testFiles'] ?? 0;

  final out = <String>[
    'project: ${_projectName()}  ·  ${files.length} files / '
        '${providers.length} providers / ${graph.edges.length} edges'
        '${testFiles > 0 ? ' / $testFiles test files' : ''}'
        '  (graph: docs/maps/code_graph.json)',
  ];

  // areas = first-two-path-segment groups (lib/<x>, packages/<x>), top 12 by
  // file count.
  String? areaOf(String path) {
    final segs = path.split('/');
    // A file directly under lib/ (e.g. lib/main.dart, 2 segments) has no
    // real area — only group files that live at least one directory deep.
    return segs.length < 3 ? null : '${segs[0]}/${segs[1]}';
  }

  final areaFiles = <String, int>{};
  final areaProviders = <String, int>{};
  for (final f in files) {
    final area = areaOf(bare(f.id));
    if (area == null) continue;
    areaFiles[area] = (areaFiles[area] ?? 0) + 1;
  }
  for (final p in providers) {
    final area = areaOf(p.declaredIn!);
    if (area == null) continue;
    areaProviders[area] = (areaProviders[area] ?? 0) + 1;
  }
  final rankedAreas = areaFiles.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  out.add(
    'areas (files/providers): '
    '${rankedAreas.take(12).map((e) => '${e.key} ${e.value}/${areaProviders[e.key] ?? 0}').join(' · ')}',
  );

  // top files by in-degree (top 8).
  final rankedFiles = files.toList()
    ..sort((a, b) {
      final byDeg = (graph.inDeg[b.id] ?? 0).compareTo(graph.inDeg[a.id] ?? 0);
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  out.add(
    'top files by in-degree: '
    '${rankedFiles.take(8).map((f) => '${bare(f.id)} ·${graph.inDeg[f.id] ?? 0}').join(', ')}',
  );

  // top providers by readers (top 8).
  final readerCount = <String, int>{};
  for (final p in providers) {
    final id = p.id;
    final n = graph.edges
        .where(
          (e) => e.dst == id && providerConsumerRels.contains(e.rel),
        )
        .length;
    readerCount[p.name!] = (readerCount[p.name!] ?? 0) + n;
  }
  final rankedProviders = readerCount.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  out.add(
    'top providers by readers: '
    '${rankedProviders.take(8).map((e) => '${e.key} ·${e.value}').join(', ')}',
  );

  // entry points: files whose path ends with main.dart.
  final entryPoints = files
      .map((f) => bare(f.id))
      .where((p) => p.endsWith('main.dart'))
      .toList()
    ..sort();
  out.add(
    'entry points: '
    '${entryPoints.isEmpty ? '(none)' : entryPoints.join(', ')}',
  );

  final navTotal = graph.edges.where((e) => e.rel == 'navigates').length;
  final navResolved =
      graph.edges.where((e) => e.rel == 'navigates' && !e.unresolved).length;
  if (navTotal > 0) out.add('nav: $navResolved/$navTotal resolved');

  final notesLine = _passportNotesLine();
  if (notesLine != null) out.add(notesLine);

  out.add(
    'verbs: brief <thing> | find <x> | sym <Symbol> | skeleton <file> | '
    'wiring <file> | readers <provider>  (docs/maps/INDEX.md for area maps)',
  );

  for (final l in out) {
    stdout.writeln(l);
  }
  return 0;
}

/// One-line skew nudge for the AI at session start (the hook runs passport
/// every session): scaffolding behind (or present-but-unstamped) the binary →
/// tell it to upgrade. Null when current, or when no scaffolding exists.
String? _skewNudge() {
  final hasScaffold =
      File('.claude/hooks/code-graph-refresh.sh').existsSync() ||
          (File('CLAUDE.md').existsSync() &&
              hasClaudeBeginLine(File('CLAUDE.md').readAsStringSync()));
  if (!hasScaffold) return null;
  final scaffold = scaffoldVersion();
  final skew = skewOf(scaffold, binaryVersion);
  if (skew == ScaffoldSkew.current) return null;
  final shown = scaffold ?? 'unknown';
  return "codegraph: skills are v$shown (binary v$binaryVersion) — "
      "run 'codegraph upgrade' to refresh";
}

/// `notes: <name1>, <name2>, …` line — sorted note names, cap
/// 10 then `… N more`. Null when `docs/maps/notes/` doesn't exist or is
/// empty (nothing to report).
String? _passportNotesLine() {
  final dir = Directory('docs/maps/notes');
  if (!dir.existsSync()) return null;
  final names = dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path.split(Platform.pathSeparator).last)
      .where((n) => n.endsWith('.md'))
      .map((n) => n.substring(0, n.length - '.md'.length))
      .toList()
    ..sort();
  if (names.isEmpty) return null;
  final shown = names.take(10).join(', ');
  final more = names.length > 10 ? ', … ${names.length - 10} more' : '';
  return 'notes: $shown$more (docs/maps/notes/)';
}
