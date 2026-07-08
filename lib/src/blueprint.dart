// `codegraph blueprint <feature-dir>` — a PLANNING primitive: turn an exemplar
// feature into a build-order plan an AI can copy to create an analogous one.
//
// It is deliberately NOT `brief`. brief ranks a feature's CURRENT state by
// importance (in-degree, reader counts) — great for understanding. blueprint
// abstracts the three graph-derivable things brief can't show for CREATION:
//   1. LAYERED BUILD-ORDER — the intra-feature directory (domain → data →
//      application → presentation → routing) is the "create files in this
//      order" signal; brief sorts by in-degree, not layer.
//   2. WIRING TOPOLOGY — watch/read/listen deps split into INTERNAL (declared
//      in the feature) vs EXTERNAL (the cross-area seam a new feature must
//      connect to), as a reusable pattern not a ranking. Grouped by DECLARING
//      FILE: these edges are file-granular, so a file declaring >1 provider
//      shows ONE file-level deps entry (disclosed as such) rather than
//      cross-attributing an edge to a provider that doesn't own it.
//   3. NAMING CONVENTIONS — the filename-suffix + provider-name template the
//      exemplar actually uses, to mirror.
// Plus routes registered and test coverage.
//
// Never-guess: every line is structure the graph STATES (files, roles,
// symbols, declares/watches/reads/listens/navigates edges). No file the new
// feature "should" have beyond the exemplar's own roles is invented.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'model.dart';

/// Canonical top-segment build-order rank for LAYERED features. Anything not
/// listed sorts after these (alpha) — see [_layerRank].
const _layerOrder = [
  'domain',
  'data',
  'application',
  'presentation',
  'routing'
];

/// Role build-order rank for FLAT features (files directly under the prefix,
/// no layer dirs) — the dependency order a repository→…→widget stack builds in.
const _roleOrder = [
  'state/model',
  'repository',
  'application',
  'logic',
  'provider',
  'controller',
  'view',
  'widget',
  'routing',
  'misc',
];

/// Filename suffixes worth reporting as a naming template when they occur.
const _knownSuffixes = [
  '_repository.dart',
  '_repository_provider.dart',
  '_provider.dart',
  '_controller.dart',
  '_notifier.dart',
  '_service.dart',
  '_service_provider.dart',
  '_failure.dart',
  '_state.dart',
  '_page.dart',
  '_view.dart',
  '_routes.dart',
  '_models.dart',
  '_mapper.dart',
  '_parser.dart',
];

int _layerRank(String topSeg) {
  final i = _layerOrder.indexOf(topSeg);
  return i < 0 ? _layerOrder.length : i;
}

int _roleRank(String? role) {
  final i = _roleOrder.indexOf(role ?? 'misc');
  return i < 0 ? _roleOrder.length : i;
}

/// `int run(List<String> args)` — resolve the feature dir + emit the plan.
int run(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 300;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: blueprint <feature-dir>');
    return 64;
  }
  final arg = positional[1];

  final graph = Graph.load();
  if (graph == null) return 66;

  // Resolve arg to a feature prefix (a dir). Accept with/without trailing
  // slash; must match >=1 file.
  final prefix = arg.endsWith('/') ? arg : '$arg/';
  final files = graph.nodes
      .where((n) => n.isFile && n.id.startsWith('file:$prefix'))
      .toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  if (files.isEmpty) {
    stderr.writeln('no files under "$prefix" — try: find $arg');
    return 64;
  }

  return asJson
      ? _json(graph, prefix, files, budget)
      : _text(graph, prefix, files, budget);
}

/// The intra-feature dir path (between the feature prefix and the filename),
/// e.g. `presentation/widget`, or `''` for a file directly under the prefix.
String _intraDir(String barePath, String prefix) {
  final rest = barePath.substring(prefix.length); // e.g. presentation/x.dart
  final slash = rest.lastIndexOf('/');
  return slash < 0 ? '' : rest.substring(0, slash);
}

/// True when the feature has any layer subdirectory (a file not directly under
/// the prefix) — otherwise it's FLAT and we group by role.
bool _isLayered(List<GraphNode> files, String prefix) =>
    files.any((f) => _intraDir(bare(f.id), prefix).isNotEmpty);

/// Ordered (label, files) groups: by intra-dir for layered features (layer
/// rank then sub-dir alpha), else by role (role rank).
List<MapEntry<String, List<GraphNode>>> _groups(
    List<GraphNode> files, String prefix) {
  final layered = _isLayered(files, prefix);
  final byKey = <String, List<GraphNode>>{};
  for (final f in files) {
    final key = layered ? _intraDir(bare(f.id), prefix) : (f.role ?? 'misc');
    (byKey.putIfAbsent(key, () => [])).add(f);
  }
  final keys = byKey.keys.toList()
    ..sort((a, b) {
      if (layered) {
        final ra = _layerRank(a.split('/').first);
        final rb = _layerRank(b.split('/').first);
        return ra != rb ? ra.compareTo(rb) : a.compareTo(b);
      }
      final ra = _roleRank(a);
      final rb = _roleRank(b);
      return ra != rb ? ra.compareTo(rb) : a.compareTo(b);
    });
  return [
    for (final k in keys)
      MapEntry(layered && k.isEmpty ? '(root)' : k,
          byKey[k]!..sort((a, b) => a.id.compareTo(b.id))),
  ];
}

/// Key declared symbols (class/fn names) for a file, capped.
String _symList(GraphNode f) {
  final names = f.symbols
      .where((s) =>
          const {'class', 'mixin', 'enum', 'fn', 'typedef'}.contains(s.kind))
      .map((s) => s.name)
      .toList();
  return names.isEmpty ? '' : ' — ${joinCapped(names)}';
}

/// One declaring FILE's provider wiring. Watch/read/listen edges are
/// FILE-granular (the graph's src is the file, not the exact provider), so deps
/// are computed ONCE per file and, when the file declares >1 provider, MUST NOT
/// be split per provider — that would assert an edge the graph does not state.
///
/// [providers] are the provider names+kinds this file declares (sorted).
/// [fileGranular] is true when there is >1, i.e. the deps are file-level and
/// disclosed as such rather than attributed to any single provider.
class _Wiring {
  _Wiring(this.file, this.providers, this.internal, this.external);

  /// bare declaring-file path (for sorting + display).
  final String file;

  /// `(name, kind, role)` for each provider declared in this file, name-sorted.
  final List<(String name, String kind, String? role)> providers;

  /// in-feature provider deps of this file (names, sorted; own providers dropped).
  final List<String> internal;

  /// `name ← declaring-file` for outside deps (sorted).
  final List<String> external;

  bool get fileGranular => providers.length > 1;
}

/// Provider-wiring topology, grouped by DECLARING FILE. `externalSeam` collects
/// the deduped external targets (`name ← file`).
///
/// Watch/read/listen edges are file-granular, so a file's deps are computed
/// once from that file's edges (dropping any dep that is one of the file's OWN
/// declared providers). Single-provider files keep a precise per-provider line;
/// multi-provider files disclose file-level deps rather than cross-attribute an
/// edge to a provider that doesn't own it. Returned sorted by file path.
/// Every cross-area provider consumed by ANY file in the feature — pages,
/// widgets, services, not just provider-declaring files. Broader than the
/// per-provider wiring's external set (an authorization page reads `authProvider`
/// / `selfCacheProvider` without declaring a provider, so those seams were
/// invisible to `_topology`'s provider-only scan — surfaced by an A/B eval).
/// Mirrors brief's cross-area computation. `name ← declaring-file`, sorted.
List<String> _externalSeam(Graph graph, String prefix, Set<String> fileIds) {
  const usage = {'watches', 'reads', 'listens'};
  final seam = <String, String>{};
  for (final e in graph.edges) {
    if (!fileIds.contains(e.src) || !usage.contains(e.rel)) continue;
    final target = graph.byId[e.dst];
    if (target == null || !target.isProvider) continue;
    final declaredIn = target.declaredIn!;
    if (declaredIn.startsWith(prefix)) continue; // internal to the feature
    seam[target.name!] = declaredIn;
  }
  return seam.entries.map((e) => '${e.key} ← ${e.value}').toList()..sort();
}

List<_Wiring> _topology(Graph graph, String prefix, Set<String> fileIds) {
  final seam = <String, String>{}; // provider name -> declaring file
  // Providers grouped by their declaring file (bare path).
  final byFile = <String, List<GraphNode>>{};
  for (final n in graph.nodes) {
    if (!n.isProvider || !fileIds.contains('file:${n.declaredIn}')) continue;
    (byFile.putIfAbsent(n.declaredIn!, () => [])).add(n);
  }

  final wirings = <_Wiring>[];
  final files = byFile.keys.toList()..sort();
  for (final file in files) {
    final decls = byFile[file]!..sort((a, b) => a.name!.compareTo(b.name!));
    final ownNames = decls.map((p) => p.name!).toSet();
    final internal = <String>{};
    final external = <String>{};
    for (final rel in const ['watches', 'reads', 'listens']) {
      for (final e
          in graph.edges.where((e) => e.src == 'file:$file' && e.rel == rel)) {
        if (!e.dst.startsWith('provider:')) continue;
        final target = graph.byId[e.dst];
        if (target == null || !target.isProvider) continue;
        if (ownNames.contains(target.name)) continue; // file's own provider
        final declaredIn = target.declaredIn!;
        if (declaredIn.startsWith(prefix)) {
          internal.add(target.name!);
        } else {
          external.add(target.name!);
          seam[target.name!] = declaredIn;
        }
      }
    }
    wirings.add(_Wiring(
      file,
      [
        for (final p in decls)
          (p.name!, p.providerType ?? '?', graph.byId['file:$file']?.role),
      ],
      internal.toList()..sort(),
      external.map((n) => '$n ← ${seam[n]}').toList()..sort(),
    ));
  }
  return wirings;
}

/// Filename suffixes from [_knownSuffixes] that occur >=1 time, sorted.
List<String> _namingSuffixes(List<GraphNode> files) {
  final found = <String>{};
  for (final f in files) {
    final base = bare(f.id).split('/').last;
    for (final s in _knownSuffixes) {
      if (base.endsWith(s)) found.add('*$s');
    }
  }
  return found.toList()..sort();
}

/// Observed provider-name suffix patterns (`xProvider`, `xNotifier`), sorted.
List<String> _providerNamePatterns(Graph graph, Set<String> fileIds) {
  final pats = <String>{};
  for (final n in graph.nodes) {
    if (!n.isProvider || !fileIds.contains('file:${n.declaredIn}')) continue;
    if (n.name!.endsWith('Provider')) pats.add('*Provider');
    if (n.name!.endsWith('Notifier')) pats.add('*Notifier');
  }
  return pats.toList()..sort();
}

// ---------------------------------------------------------------------------
// text

int _text(Graph graph, String prefix, List<GraphNode> files, int budget) {
  final fileIds = files.map((f) => f.id).toSet();
  final feature = prefix.substring(0, prefix.length - 1);
  final groups = _groups(files, prefix);
  final wirings = _topology(graph, prefix, fileIds);
  final seam = _externalSeam(graph, prefix, fileIds);
  final providerCount = wirings.fold<int>(0, (n, w) => n + w.providers.length);

  final header = <String>[
    'blueprint: $feature — ${files.length} files, ${groups.length} layers, '
        '$providerCount providers',
    'intent: a map of the exemplar\'s STRUCTURE — not a finished plan. Use the '
        'layers/wiring to orient, then do the real work in STUDY THESE + '
        'DECISIONS below (read the patterns, make the judgment calls the graph '
        'can\'t). Structure is the easy 20%.',
    '',
  ];

  // Two LONG list sections (LAYERS + WIRING) — these get the line budget.
  final longList = <String>[];

  // 1. Layers (build order).
  longList.add('LAYERS (build in this order):');
  for (final g in groups) {
    longList.add('  ${g.key}/');
    for (final f in g.value) {
      final base = bare(f.id).split('/').last;
      final role = f.role != null ? ' [${f.role}]' : '';
      longList.add('    $base$role${_symList(f)}');
    }
  }
  longList.add('');

  // 2. Provider wiring topology — grouped by DECLARING FILE. A file declaring
  //    exactly 1 provider keeps a precise per-provider line. A file declaring
  //    >1 provider emits ONE file-level entry whose deps are labeled
  //    file-granular — never cross-attributed to a single provider.
  longList.add('PROVIDER WIRING (the reusable dependency pattern):');
  if (wirings.isEmpty) {
    longList.add('  (no providers declared)');
  } else {
    for (final w in wirings) {
      if (!w.fileGranular) {
        final (name, kind, role) = w.providers.single;
        final roleStr = role != null ? ', $role' : '';
        longList.add('  $name ($kind$roleStr)');
        _depLines(w).forEach(longList.add);
      } else {
        final names = w.providers.map((p) => '${p.$1} (${p.$2})').join(', ');
        final base = w.file.split('/').last;
        longList.add('  $base declares ${w.providers.length} providers:');
        longList.add('    $names');
        longList.add('    file-level deps (watch/read/listen edges are '
            'file-granular — not split per provider):');
        if (w.internal.isNotEmpty) {
          longList.add('      internal: ${joinCapped(w.internal)}');
        }
        if (w.external.isNotEmpty) {
          longList.add('      external: ${joinCapped(w.external)}');
        }
        if (w.internal.isEmpty && w.external.isEmpty) {
          longList.add('      (no provider deps)');
        }
      }
    }
  }
  longList.add('');

  // SHORT tail sections — always emitted (bounded; the most useful for
  // scaffolding, so never starved by a truncated LAYERS/WIRING list).
  final tail = <String>[];

  // 3. External seam.
  tail.add('EXTERNAL SEAM (cross-area providers to wire to):');
  if (seam.isEmpty) {
    tail.add('  (none)');
  } else {
    for (final s in seam) {
      tail.add('  $s');
    }
  }
  tail.add('');

  // 4. Routes registered.
  final routes = _routes(graph, files);
  tail.add('ROUTES REGISTERED:');
  if (routes.isEmpty) {
    tail.add('  (none)');
  } else {
    for (final r in routes) {
      tail.add('  $r');
    }
  }
  tail.add('');

  // 5. Naming conventions.
  final suffixes = _namingSuffixes(files);
  final namePats = _providerNamePatterns(graph, fileIds);
  tail.add('NAMING CONVENTIONS (mirror these):');
  tail.add(
      '  file suffixes: ${suffixes.isEmpty ? '(none)' : suffixes.join(', ')}');
  tail.add(
      '  provider names: ${namePats.isEmpty ? '(none)' : namePats.join(', ')}');
  tail.add('');

  // 6. Tests.
  final tested = files.where((f) => f.testRefs > 0).toList();
  final untested = files.where((f) => f.testRefs == 0).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  tail.add(
      'TESTS: ${tested.length}/${files.length} files have test references');
  if (untested.isNotEmpty) {
    tail.add('  untested (add coverage):');
    for (final f in untested) {
      tail.add('    ${bare(f.id).split('/').last}');
    }
  }
  tail.add('');

  // 7. STUDY THESE — the structure above is inert without the PATTERNS. Point
  //    the agent at the exemplar's highest-signal files and say what to learn
  //    from each, so it reads and reasons instead of copying a skeleton blind.
  tail.add(
      'STUDY THESE (read the patterns before building — this is the work):');
  final study = _studyThese(files);
  if (study.isEmpty) {
    tail.add(
        '  (flat feature — read every file above; no layer signal to rank)');
  } else {
    for (final s in study) {
      tail.add('  $s');
    }
  }
  tail.add('');

  // 8. DECISIONS THE GRAPH CAN'T MAKE — the graph states structure, never
  //    runtime behavior, backend contracts, or intent. Name the judgment calls
  //    so the agent stops, reads, and DECIDES rather than assuming the skeleton
  //    is the whole answer. Framed as questions (never asserts a fact).
  tail.add('DECISIONS THE GRAPH CAN\'T MAKE (your judgment — read + reason):');
  for (final q in _openQuestions(files)) {
    tail.add('  - $q');
  }

  for (final l in header) {
    stdout.writeln(l);
  }
  emit(longList, budget, hint: 'raise --budget ${longList.length}');
  for (final l in tail) {
    stdout.writeln(l);
  }
  return 0;
}

/// The precise per-provider dep lines for a single-provider file entry.
List<String> _depLines(_Wiring w) => [
      if (w.internal.isNotEmpty) '    → internal: ${joinCapped(w.internal)}',
      if (w.external.isNotEmpty) '    → external: ${joinCapped(w.external)}',
      if (w.internal.isEmpty && w.external.isEmpty) '    → (no provider deps)',
    ];

/// The highest-signal files to READ (with WHAT pattern to extract), so the
/// agent studies the exemplar's conventions instead of copying a skeleton. Only
/// emits a category when a matching file actually exists (never points at a file
/// the feature doesn't have). Deterministic: first match per category by path.
List<String> _studyThese(List<GraphNode> files) {
  final sorted = files.toList()..sort((a, b) => a.id.compareTo(b.id));
  String? pick(bool Function(String base, String? role) match) {
    for (final f in sorted) {
      if (match(bare(f.id).split('/').last, f.role)) return bare(f.id);
    }
    return null;
  }

  final out = <String>[];
  void add(String? file, String why) {
    if (file != null) out.add('$file\n      → $why');
  }

  add(
      pick((b, r) => r == 'controller' || b.endsWith('_controller.dart')),
      'STATE ORCHESTRATION — how it sequences repository/service calls, the '
      'Notifier/AsyncNotifier shape, copyWith conventions, and error surfacing. '
      'This is the heart of the feature; understand it fully.');
  add(
      pick((b, r) =>
          b.contains('failure') || b.contains('error') && r != 'view'),
      'ERROR TAXONOMY — the sealed failure hierarchy and which cases the flow '
      'distinguishes; your feature must model the same distinctions.');
  add(
      pick((b, r) => r == 'repository' || b.endsWith('_repository.dart')),
      'DATA/API CONTRACT — how the Dio client is built, the request/response '
      'shapes, and the backend endpoints it calls.');
  add(
      pick((b, r) => r == 'view' || b.endsWith('_page.dart')),
      'UI COMPOSITION — how the screen wires providers to widgets and derives '
      'view state from the controller\'s AsyncValue.');
  add(
      pick((b, r) => r == 'routing' || b.endsWith('_routes.dart')),
      'ROUTE REGISTRATION — the path constant, navigator key, page transition, '
      'and where it plugs into the app router.');
  return out;
}

/// The judgment calls the graph can't answer — tailored to what the feature
/// actually contains so it isn't boilerplate. Always framed as questions the
/// agent must resolve by reading + reasoning, so the tool prompts deeper
/// thinking rather than terminating it.
List<String> _openQuestions(List<GraphNode> files) {
  final bases = files.map((f) => bare(f.id).split('/').last).toList();
  bool any(bool Function(String) p) => bases.any(p);
  final out = <String>[
    'RUNTIME BEHAVIOR — the graph shows WHAT is wired, never WHY or in what '
        'order. Trace the controller\'s actual call sequence and lifecycle '
        'before replicating it.',
  ];
  if (any((b) => b.contains('platform') || b.contains('channel'))) {
    out.add('NATIVE BRIDGE — a platform/channel file exists. Does the new '
        'feature reuse the existing native channel or need a new one? '
        '(Standard 11 — outside pure-Dart scope.)');
  }
  if (any((b) =>
      b.contains('repository') ||
      b.contains('_models') ||
      b.contains('dto') ||
      b.contains('_api'))) {
    out.add('BACKEND CONTRACT — the graph can\'t see endpoints. Does this need '
        'a NEW API target / base URL / environment config, or reuse an '
        'existing one? Confirm the backend contract before coding the '
        'repository.');
  }
  if (any((b) => b.contains('widget') || b.endsWith('_view.dart'))) {
    out.add('SHARED vs DUPLICATED UI — can these widgets be parameterized and '
        'shared, or must they stay feature-isolated per the standards? Don\'t '
        'copy-paste without deciding.');
  }
  out.add('CROSS-CUTTING — i18n namespace, feature flags, analytics, '
      'permissions, and localization keys the structure doesn\'t reveal. '
      'Enumerate what THIS feature needs.');
  out.add('WHY THIS SHAPE — is every layer/provider in the exemplar actually '
      'needed here, or is some of it incidental to the original\'s history? '
      'Justify each piece rather than cargo-culting the structure.');
  return out;
}

/// Routes the feature registers: navigates lines from every feature file, plus
/// files whose role is `routing`. Sorted, deduped.
List<String> _routes(Graph graph, List<GraphNode> files) {
  final lines = <String>{};
  for (final f in files) {
    for (final l in graph.navLines(f.id)) {
      lines.add(l);
    }
    if (f.role == 'routing') {
      lines.add('${bare(f.id).split('/').last} [routing]');
    }
  }
  return lines.toList()..sort();
}

// ---------------------------------------------------------------------------
// json

int _json(Graph graph, String prefix, List<GraphNode> files, int cap) {
  final fileIds = files.map((f) => f.id).toSet();
  final feature = prefix.substring(0, prefix.length - 1);
  final groups = _groups(files, prefix);
  final wirings = _topology(graph, prefix, fileIds);
  final seam = _externalSeam(graph, prefix, fileIds);
  final budget = Budget(cap);

  final layers = [
    for (final g in budget.take(groups))
      {
        'label': g.key,
        'files': [
          for (final f in g.value)
            {
              'file': bare(f.id),
              if (f.role != null) 'role': f.role,
              'symbols': f.symbols
                  .where((s) => const {
                        'class',
                        'mixin',
                        'enum',
                        'fn',
                        'typedef'
                      }.contains(s.kind))
                  .map((s) => s.name)
                  .toList(),
              'tested': f.testRefs > 0,
            },
        ],
      },
  ];

  final providers = [
    for (final w in budget.take(wirings))
      if (!w.fileGranular)
        {
          'name': w.providers.single.$1,
          'kind': w.providers.single.$2,
          if (w.providers.single.$3 != null) 'role': w.providers.single.$3,
          'fileGranular': false,
          'internal': w.internal,
          'external': w.external,
        }
      else
        {
          'file': w.file,
          'fileGranular': true,
          'providers': [for (final p in w.providers) p.$1],
          // File-granular deps — deliberately NOT attributed to any single
          // provider (the graph's watch/read/listen edges are file-level).
          'internal': w.internal,
          'external': w.external,
        },
  ];

  final routes = budget.take(_routes(graph, files));
  final untested = files
      .where((f) => f.testRefs == 0)
      .map((f) => bare(f.id))
      .toList()
    ..sort();

  stdout.writeln(jsonEncode({
    'verb': 'blueprint',
    'feature': feature,
    'files': files.length,
    'layers': layers,
    'providers': providers,
    'externalSeam': seam,
    'routes': routes,
    'naming': {
      'fileSuffixes': _namingSuffixes(files),
      'providerNames': _providerNamePatterns(graph, fileIds),
    },
    'tests': {
      'tested': files.where((f) => f.testRefs > 0).length,
      'total': files.length,
      'untested': budget.take(untested),
    },
    // The "now do the real work" guidance — patterns to read + judgment calls
    // the graph can't make, so a skill consuming this pushes deeper thinking
    // rather than treating the structure as the finished plan.
    'studyThese': _studyThese(files),
    'decisions': _openQuestions(files),
    if (budget.truncated) 'truncated': true,
  }));
  return 0;
}
