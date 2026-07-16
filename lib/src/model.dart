// Typed graph model: `GraphNode`/`GraphEdge`/`Graph`, replacing the untyped
// `Map<String, dynamic>` nodes/edges every consumer used to pass around.
//
// Wire format is FROZEN: `Graph.toJson()` reproduces
// `engine.dart`'s old `_writeGraph` key order and key-presence rules exactly,
// byte-for-byte, so existing consumers of docs/maps/code_graph.json (and the
// round-trip/determinism tests) never see a diff from this refactor alone —
// no new fields, no reordering, no behavior change.
//
// ## The `provider:name@file` / `ambiguous` sentinel
//
// A provider name declared more than once gets one node per declaration,
// id'd `provider:<name>@<file>` (see `engine.dart`'s `_ProviderResolver`).
// Each such node carries `ambiguous: true` ([GraphNode.isAmbiguousProvider]).
// A provider-interaction edge that can't be resolved to exactly
// one reachable declaration points at the bare `provider:<name>` id (no
// `@file`) and carries `ambiguous: true` plus a `candidates` list of every
// declaring file ([GraphEdge.isUnresolvedAmbiguous]) — this is the
// "unresolved" sentinel every call site used to check via raw string/bool
// comparisons.
import 'dart:convert';
import 'dart:io';

export 'signatures.dart';

import 'signatures.dart';

const _defaultGraphPath = 'docs/maps/code_graph.json';

/// Current wire-format generation (`stats.format`). Bumped on additive schema
/// changes; `Graph.load()` warns (stderr, never fails) when a loaded graph's
/// `format` is missing (pre-0.6) or newer than this binary knows.
const graphFormatVersion = 9;

/// Stable display order for every Riverpod provider interaction Codegraph
/// models. Dependency reads come first, then state-changing interactions.
const providerInteractionRelOrder = [
  'watches',
  'reads',
  'listens',
  'invalidates',
  'refreshes',
];

/// THE set of provider-interaction relations (`GraphEdge.rel` values a
/// provider-use edge can carry). These all matter to impact and unused-provider
/// analysis: a provider that is only invalidated or refreshed is still used.
const providerConsumerRels = {
  'watches',
  'reads',
  'listens',
  'invalidates',
  'refreshes',
};

/// Roles a file needs to have to count as a coverage gap in `untested files`
/// — the Standard-07-shaped set (view/controller/repository/provider); a
/// `misc`/`widget`/etc. file isn't expected to carry its own test file.
/// Shared by `query.dart`'s `untested` verb and `diff.dart`'s blast-radius
/// card so the definition of "untested" cannot drift between them.
const untestedRoles = {'view', 'controller', 'repository', 'provider'};

/// A node in the graph: a `file` (one per parsed Dart file) or a `provider`
/// (one per Riverpod provider declaration).
class GraphNode {
  GraphNode.file({
    required this.id,
    required this.role,
    required this.label,
    required this.symbols,
    this.testRefs = 0,
  })  : kind = 'file',
        name = null,
        providerType = null,
        autoDispose = null,
        declaredIn = null,
        line = null,
        ambiguous = false;

  GraphNode.provider({
    required this.id,
    required this.name,
    required this.providerType,
    required bool autoDispose,
    required this.declaredIn,
    required int line,
    required this.ambiguous,
    this.testRefs = 0,
  })  : kind = 'provider',
        autoDispose = autoDispose,
        line = line,
        role = null,
        label = null,
        symbols = const [];

  GraphNode._raw(
      this.id,
      this.kind,
      this.role,
      this.label,
      this.symbols,
      this.name,
      this.providerType,
      this.autoDispose,
      this.declaredIn,
      this.line,
      this.ambiguous,
      this.testRefs);

  factory GraphNode.fromJson(Map<String, dynamic> j) {
    if (j['kind'] == 'file') {
      final syms = (j['symbols'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map(SymbolRec.fromJson)
              .toList() ??
          const <SymbolRec>[];
      return GraphNode._raw(
        j['id'] as String,
        'file',
        j['role'] as String?,
        j['label'] as String?,
        syms,
        null,
        null,
        null,
        null,
        null,
        false,
        j['testRefs'] as int? ?? 0,
      );
    }
    return GraphNode._raw(
      j['id'] as String,
      'provider',
      null,
      null,
      const [],
      j['name'] as String?,
      j['providerType'] as String?,
      j['autoDispose'] as bool?,
      j['declaredIn'] as String?,
      j['line'] as int?,
      j['ambiguous'] == true,
      j['testRefs'] as int? ?? 0,
    );
  }

  final String id;
  final String kind; // 'file' | 'provider'

  // file fields
  final String? role;
  final String? label;
  final List<SymbolRec> symbols;

  // provider fields
  final String? name;
  final String? providerType;
  final bool? autoDispose;
  final String? declaredIn;
  final int? line;

  /// True when this provider declaration's name is shared by >1 declaration
  /// (id is `provider:name@file`, not the plain `provider:name`) — see the
  /// sentinel doc above.
  final bool ambiguous;

  /// Number of test FILES (test/, integration_test/, patrol_test/) that
  /// reference this node — a resolved lib import for a file node, or a
  /// token-set match on the provider's name for a provider node (candidate
  /// data: a name match, not a resolved reference — see engine.dart's test
  /// scan). 0 when no test root references it.
  final int testRefs;

  bool get isFile => kind == 'file';
  bool get isProvider => kind == 'provider';

  /// Alias of [ambiguous] for provider nodes — reads better at call sites
  /// than the bare field name (matches [GraphEdge.isUnresolvedAmbiguous]).
  bool get isAmbiguousProvider => ambiguous;

  Map<String, dynamic> toJson() {
    if (kind == 'file') {
      return {
        'id': id,
        'kind': 'file',
        'role': role,
        'label': label,
        if (testRefs != 0) 'testRefs': testRefs,
        if (symbols.isNotEmpty)
          'symbols': symbols.map((s) => s.toJson()).toList(),
      };
    }
    return {
      'id': id,
      'kind': 'provider',
      'name': name,
      'providerType': providerType,
      'autoDispose': autoDispose,
      'declaredIn': declaredIn,
      'line': line,
      if (testRefs != 0) 'testRefs': testRefs,
      if (ambiguous) 'ambiguous': true,
    };
  }

  /// ` · test-only (N test refs)` when [testRefs] > 0, else `''` — appended
  /// by `unused`/ATTENTION's zero-lib-consumer sections so a provider or file
  /// only reached from tests reads as a known case, not a dead-code false
  /// positive (candidate data — see [testRefs] doc).
  String get testOnlySuffix =>
      testRefs > 0 ? ' · test-only ($testRefs test refs)' : '';
}

/// An edge: `src` --[`rel`]--> `dst`, plus relation-specific optional fields.
class GraphEdge {
  GraphEdge({
    required this.src,
    required this.rel,
    required this.dst,
    this.line,
    this.external = false,
    this.ambiguous = false,
    this.candidates,
    this.detail,
    this.unresolved = false,
    this.childName,
    this.parentName,
    this.confidence = 'heuristic',
    this.routeSymbol,
    this.operation,
  });

  factory GraphEdge.fromJson(Map<String, dynamic> j) => GraphEdge(
        src: j['src'] as String,
        rel: j['rel'] as String,
        dst: j['dst'] as String,
        line: j['line'] as int?,
        external: j['external'] == true,
        ambiguous: j['ambiguous'] == true,
        candidates: (j['candidates'] as List?)?.cast<String>(),
        detail: j['detail'] as String?,
        unresolved: j['unresolved'] == true,
        childName: j['child'] as String?,
        parentName: j['parent'] as String?,
        confidence: j['confidence'] as String? ?? 'heuristic',
        routeSymbol: j['routeSymbol'] as String?,
        operation: j['operation'] as String?,
      );

  final String src;
  final String rel;
  final String dst;
  final int? line;
  final bool external;
  final bool ambiguous;
  final List<String>? candidates;
  final String? detail;

  /// Typed subtype-edge fields (format 6+): the subclass/subtype name and the
  /// supertype name it names in its extends/implements/with/on clause. Set on
  /// `implements/extends` edges only. Null on graphs written before format 6
  /// (and on every other edge kind) — callers fall back to parsing [detail]'s
  /// `'child -> parent'` text for those.
  final String? childName;
  final String? parentName;

  /// How this edge was derived (3.0 Stage 2, the NEVER-GUESS doctrine as data):
  ///   `resolved`  - backed by element identity (the analyzer confirmed it),
  ///                 e.g. a reader whose receiver's static type IS a Ref.
  ///   `heuristic` - a name/token/URI match, not element-confirmed (the default
  ///                 and the only value a syntax build can produce).
  ///   `guessed`   - inferred via a refusal-gated substitution (e.g. nav
  ///                 constant inlining).
  /// Lets a query or the future actuator filter by trust (act only on
  /// `resolved`). Absent in JSON means `heuristic` (kept lean like the flags).
  final String confidence;
  final String? routeSymbol;
  final String? operation;

  /// True on a `navigates` edge when no sibling `navigates-to` edge (same
  /// `src`+`line`) was emitted — the resolver couldn't map the nav target to
  /// a page file. Absence of this flag is NOT a positive resolved signal by
  /// itself; join on the `navigates-to` sibling for that (see [Graph.navLines]).
  final bool unresolved;

  /// True when this is a provider-interaction edge that `_ProviderResolver`
  /// could not resolve to exactly one reachable declaration — see the
  /// sentinel doc above. `dst` is the bare `provider:<name>` id and
  /// [candidates] lists every declaring file.
  bool get isUnresolvedAmbiguous => ambiguous;

  /// Human-readable destination: provider ids lose their `provider:` prefix
  /// (an `@file`-disambiguated id renders as `name (ambiguous, see readers)`
  /// — the name plus a pointer to the detail command, not the raw path);
  /// file/route/type ids lose their kind prefix.
  String get dstDisplayName {
    if (dst.startsWith('provider:')) {
      final id = dst.substring('provider:'.length);
      final at = id.indexOf('@');
      return at < 0 ? id : '${id.substring(0, at)} (ambiguous, see readers)';
    }
    return dst
        .replaceFirst('file:', '')
        .replaceFirst('route:', '')
        .replaceFirst('type:', '');
  }

  Map<String, dynamic> toJson() => {
        'src': src,
        'rel': rel,
        'dst': dst,
        if (external) 'external': true,
        if (ambiguous) 'ambiguous': true,
        if (candidates != null) 'candidates': candidates,
        if (line != null) 'line': line,
        if (detail != null) 'detail': detail,
        if (unresolved) 'unresolved': true,
        if (childName != null) 'child': childName,
        if (parentName != null) 'parent': parentName,
        if (confidence != 'heuristic') 'confidence': confidence,
        if (routeSymbol != null) 'routeSymbol': routeSymbol,
        if (operation != null) 'operation': operation,
      };
}

/// One occurrence in a resolved go_router_builder annotation tree.
///
/// A route-data class may occur more than once (relative routes explicitly
/// support reuse), so [id] identifies the tree occurrence while [symbol]
/// identifies the Dart class. Every relationship uses occurrence ids; direct
/// navigation uses [navigationId], which remains class-identity based.
class RouteContract {
  RouteContract({
    required this.id,
    required this.symbol,
    required this.navigationId,
    required this.name,
    required this.kind,
    required this.declaredIn,
    required this.line,
    required this.annotationFile,
    required this.annotationLine,
    required this.path,
    required this.fullPath,
    required this.routeName,
    required this.caseSensitive,
    required this.parentId,
    required this.shellId,
    required this.branchId,
    required this.branchIndex,
    required this.pageFile,
    required this.navigatorKey,
    required this.navigatorKeyDeclared,
    required this.parentNavigatorKey,
    required this.parentNavigatorKeyDeclared,
    required this.navigatorOwnerId,
    required this.redirectTargets,
    required this.redirectDeclared,
    required this.redirectComplete,
    required this.uncertainties,
  });

  factory RouteContract.fromJson(Map<String, dynamic> json) => RouteContract(
        id: json['id'] as String,
        symbol: json['symbol'] as String,
        navigationId: json['navigationId'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        declaredIn: json['declaredIn'] as String?,
        line: json['line'] as int?,
        annotationFile: json['annotationFile'] as String,
        annotationLine: json['annotationLine'] as int,
        path: json['path'] as String?,
        fullPath: json['fullPath'] as String?,
        routeName: json['routeName'] as String?,
        caseSensitive: json['caseSensitive'] as bool?,
        parentId: json['parent'] as String?,
        shellId: json['shell'] as String?,
        branchId: json['branch'] as String?,
        branchIndex: json['branchIndex'] as int?,
        pageFile: json['pageFile'] as String?,
        navigatorKey: json['navigatorKey'] as String?,
        navigatorKeyDeclared: json['navigatorKeyDeclared'] == true,
        parentNavigatorKey: json['parentNavigatorKey'] as String?,
        parentNavigatorKeyDeclared: json['parentNavigatorKeyDeclared'] == true,
        navigatorOwnerId: json['navigatorOwner'] as String?,
        redirectTargets:
            (json['redirectTargets'] as List?)?.cast<String>() ?? const [],
        redirectDeclared: json['redirectDeclared'] == true,
        redirectComplete: json['redirectComplete'] == true,
        uncertainties:
            (json['uncertainties'] as List?)?.cast<String>() ?? const [],
      );

  final String id;
  final String symbol;
  final String navigationId;
  final String name;
  final String kind;
  final String? declaredIn;
  final int? line;
  final String annotationFile;
  final int annotationLine;
  final String? path;
  final String? fullPath;
  final String? routeName;
  final bool? caseSensitive;
  final String? parentId;
  final String? shellId;
  final String? branchId;
  final int? branchIndex;
  final String? pageFile;
  final String? navigatorKey;
  final bool navigatorKeyDeclared;
  final String? parentNavigatorKey;
  final bool parentNavigatorKeyDeclared;
  final String? navigatorOwnerId;
  final List<String> redirectTargets;
  final bool redirectDeclared;
  final bool redirectComplete;
  final List<String> uncertainties;

  bool get isTopLevel => parentId == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'navigationId': navigationId,
        'name': name,
        'kind': kind,
        if (declaredIn != null) 'declaredIn': declaredIn,
        if (line != null) 'line': line,
        'annotationFile': annotationFile,
        'annotationLine': annotationLine,
        if (path != null) 'path': path,
        if (fullPath != null) 'fullPath': fullPath,
        if (routeName != null) 'routeName': routeName,
        if (caseSensitive != null) 'caseSensitive': caseSensitive,
        if (parentId != null) 'parent': parentId,
        if (shellId != null) 'shell': shellId,
        if (branchId != null) 'branch': branchId,
        if (branchIndex != null) 'branchIndex': branchIndex,
        if (pageFile != null) 'pageFile': pageFile,
        if (navigatorKey != null) 'navigatorKey': navigatorKey,
        if (navigatorKeyDeclared) 'navigatorKeyDeclared': true,
        if (parentNavigatorKey != null)
          'parentNavigatorKey': parentNavigatorKey,
        if (parentNavigatorKeyDeclared) 'parentNavigatorKeyDeclared': true,
        if (navigatorOwnerId != null) 'navigatorOwner': navigatorOwnerId,
        if (redirectTargets.isNotEmpty) 'redirectTargets': redirectTargets,
        if (redirectDeclared) 'redirectDeclared': true,
        if (redirectComplete) 'redirectComplete': true,
        if (uncertainties.isNotEmpty) 'uncertainties': uncertainties,
      };
}

/// Availability/completeness envelope for resolved typed-route contracts.
/// A syntax build emits an unavailable index instead of an apparently complete
/// empty list; older graphs omit the sidecar entirely.
class RouteIndex {
  RouteIndex({
    required this.available,
    required this.complete,
    required this.unresolvedFiles,
    required this.contracts,
  });

  factory RouteIndex.fromJson(Map<String, dynamic> json) => RouteIndex(
        available: json['available'] == true,
        complete: json['complete'] == true,
        unresolvedFiles:
            (json['unresolvedFiles'] as List?)?.cast<String>() ?? const [],
        contracts: (json['contracts'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(RouteContract.fromJson)
                .toList() ??
            const [],
      );

  final bool available;
  final bool complete;
  final List<String> unresolvedFiles;
  final List<RouteContract> contracts;

  Map<String, dynamic> toJson() => {
        'format': 1,
        'available': available,
        'complete': complete,
        'unresolvedFiles': unresolvedFiles,
        'contracts': contracts.map((route) => route.toJson()).toList(),
      };
}

/// The whole resolved graph: every file/provider node, every edge, and the
/// summary stats block. `stats` is emitted verbatim (not recomputed) so
/// `toJson()` reproduces exactly what `build()` counted at write time.
class Graph {
  Graph(
      {required this.libRoot,
      required this.stats,
      required this.nodes,
      required this.edges,
      this.routeIndex})
      : byId = {for (final n in nodes) n.id: n};

  factory Graph.fromJson(Map<String, dynamic> j) => Graph(
        libRoot: j['libRoot'] as String,
        stats: (j['stats'] as Map).cast<String, int>(),
        nodes: (j['nodes'] as List)
            .cast<Map<String, dynamic>>()
            .map(GraphNode.fromJson)
            .toList(),
        edges: (j['edges'] as List)
            .cast<Map<String, dynamic>>()
            .map(GraphEdge.fromJson)
            .toList(),
        routeIndex: j['routeIndex'] is Map<String, dynamic>
            ? RouteIndex.fromJson(j['routeIndex'] as Map<String, dynamic>)
            : null,
      );

  /// Reads and parses `docs/maps/code_graph.json` (or [path]). Returns
  /// `null` (with a stderr message) when the file is missing — callers that
  /// need an exit code translate that the same way `query.loadGraph()` used
  /// to (exit 66).
  static Graph? load([String path = _defaultGraphPath]) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('No $path — run: codegraph build');
      return null;
    }
    final graph = Graph.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
    final fmt = graph.stats['format'];
    if (fmt == null) {
      stderr.writeln(
        'note: graph predates format versioning (pre-0.6) — rebuild with: '
        'codegraph build',
      );
    } else if (fmt > graphFormatVersion) {
      stderr.writeln(
        'note: graph format $fmt is newer than this binary '
        '($graphFormatVersion) — update: dart pub global activate -sgit '
        'https://github.com/ArinFaraj/codegraph',
      );
    }
    return graph;
  }

  final String libRoot;
  final Map<String, int> stats;
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final RouteIndex? routeIndex;

  List<RouteContract> get routes => routeIndex?.contracts ?? const [];

  /// node id -> node, for O(1) lookup instead of a linear `firstWhere` scan.
  final Map<String, GraphNode> byId;

  late final Map<String, RouteContract> routeById = {
    for (final route in routes) route.id: route,
  };

  late final Map<String, List<RouteContract>> routesBySymbol = () {
    final result = <String, List<RouteContract>>{};
    for (final route in routes) {
      result.putIfAbsent(route.symbol, () => []).add(route);
    }
    return result;
  }();

  /// node id -> count of incoming `imports` edges (file nodes) or
  /// `watches`/`reads`/`listens` edges (provider nodes). Computed once,
  /// lazily, and cached — moved from query.dart's module-level `_buildInDeg`.
  late final Map<String, int> inDeg = _buildInDeg();

  Map<String, int> _buildInDeg() {
    final deg = <String, int>{};
    for (final e in edges) {
      if (e.rel == 'imports' ||
          e.rel == 'watches' ||
          e.rel == 'reads' ||
          e.rel == 'listens') {
        deg[e.dst] = (deg[e.dst] ?? 0) + 1;
      }
    }
    return deg;
  }

  /// Declaration sites (`file:line`) for [symbol] — top-level symbols and
  /// class/mixin/extension members. Shared by `callers`/`refs` ambiguity notes.
  List<String> declarationsOf(String symbol) {
    final decls = <String>[];
    for (final n in nodes) {
      if (!n.isFile) continue;
      final file = n.id.replaceFirst('file:', '');
      for (final s in n.symbols) {
        if (s.name == symbol) decls.add('$file:${s.line}');
        void addMember(String entry) {
          if (isMemberCapTrailer(entry)) return;
          final parsed = parseRenderedMember(entry);
          if (parsed != null && parsed.name == symbol) {
            decls.add('$file:${parsed.line}');
          }
        }

        final memberEntries = s.memberIndex ?? s.members ?? const <String>[];
        for (final entry in memberEntries) {
          addMember(entry);
        }
      }
    }
    decls.sort();
    return decls;
  }

  Map<String, dynamic> toJson() => {
        'libRoot': libRoot,
        'stats': stats,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        if (routeIndex != null) 'routeIndex': routeIndex!.toJson(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  /// Provider nodes with zero `reads`/`watches`/`listens` edges pointing at
  /// them — the same "dead-code candidate" computation `query.dart`'s
  /// `unused providers` and `attention.dart`'s ATTENTION.md section both need
  /// (one implementation, two call sites). Caveat carried by both callers:
  /// test-only usage and `ref.read` via overrides aren't visible here, so
  /// treat this as a candidate list, not a delete list. Sorted by id.
  List<GraphNode> get unusedProviders {
    final consumed = <String>{};
    for (final e in edges) {
      if (providerConsumerRels.contains(e.rel)) {
        consumed.add(e.dst);
      }
    }
    final dead = nodes
        .where((n) => n.isProvider && !consumed.contains(n.id))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return dead;
  }

  /// Inline-resolved navigation lines for a source file id, sorted
  /// deterministically by target name then line:
  ///   resolved:     `'/details':12 → lib/x/details_page.dart`
  ///   unresolved:   `AppPaths.foo.path:34 (unresolved)`
  ///   ambiguous:    `'/a':12 → (resolved, ambiguous line)`
  /// [GraphEdge.unresolved] is authoritative (set at emission time from
  /// `pageFile == null`) — never re-derived here. A `navigates-to` sibling is
  /// only consulted to name the target, via a (src, line) join; when two
  /// different `navigates` calls share one physical line, that join can't
  /// tell which target belongs to which call, so we refuse to guess and
  /// render "(resolved, ambiguous line)" instead of borrowing a target.
  List<String> navLines(String srcId) {
    final targetsByLine = <int?, List<String>>{};
    for (final e in edges) {
      if (e.src == srcId && e.rel == 'navigates-to') {
        (targetsByLine[e.line] ??= <String>[]).add(e.dstDisplayName);
      }
    }
    final navs =
        edges.where((e) => e.src == srcId && e.rel == 'navigates').toList()
          ..sort((a, b) {
            final byName = a.dstDisplayName.compareTo(b.dstDisplayName);
            return byName != 0 ? byName : (a.line ?? 0).compareTo(b.line ?? 0);
          });
    return navs.map((e) {
      if (e.unresolved) return '${e.dstDisplayName}:${e.line} (unresolved)';
      final tgts = targetsByLine[e.line] ?? const <String>[];
      return tgts.length == 1
          ? '${e.dstDisplayName}:${e.line} → ${tgts.single}'
          : '${e.dstDisplayName}:${e.line} → (resolved, ambiguous line)';
    }).toList();
  }

  /// File nodes nothing `imports` — excluding known entrypoints (generated
  /// files, `main.dart`, widgetbook, route tables) that are legitimately only
  /// reached at runtime, not via a static import edge. Shared by
  /// `query.dart`'s `unused files` and `attention.dart`'s ATTENTION.md
  /// section. Sorted by id.
  List<GraphNode> get orphanFiles {
    final imported = <String>{};
    for (final e in edges) {
      if (e.rel == 'imports') imported.add(e.dst);
    }
    bool isEntrypoint(String id) =>
        id.endsWith('.g.dart') ||
        id.endsWith('main.dart') ||
        id.contains('/widgetbook/') ||
        id.endsWith('_routes.dart');
    final orphans = nodes
        .where(
            (n) => n.isFile && !imported.contains(n.id) && !isEntrypoint(n.id))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return orphans;
  }
}
