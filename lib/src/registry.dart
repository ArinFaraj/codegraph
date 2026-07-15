// Whole-project file registry: `FileInfo` (one per parsed Dart file) plus the
// small decl/record types its fields hold. Extracted from engine.dart so
// `nav_resolution.dart` (and anything else that only needs "what did this
// file declare") does not have to import the whole analyzer-driving god file
// to get the type. This module owns no logic, only data — it imports
// `resolution.dart` for `ProviderDecl`/`ClassDecl` and `signatures.dart` for
// `SymbolRec`, and imports NEITHER `engine.dart` NOR `nav_resolution.dart` —
// a true leaf, so anything importing this file for `FileInfo` never pulls in
// a cycle back to itself.
import 'resolution.dart' show ProviderDecl, ClassDecl;
import 'signatures.dart' show SymbolRec;

/// A `GoRoute(...)` (or `StatefulShellRoute`/etc — only `GoRoute` observed in
/// practice, see Stage 4 discovery notes) constructor call collected during
/// `_collect`/`_Visitor`: the `path:` argument's SOURCE TEXT (unresolved —
/// resolution against `navigates` expressions happens once, project-wide, in
/// `build()`) and the first class-registry-resolvable type instantiated
/// inside `builder:`/`pageBuilder:`, if any. [name] is the `name:` argument's
/// quoted-string SOURCE TEXT (including quotes, e.g. `'lit'`) when present —
/// mechanism (c)'s `goNamed` half (0.5.0) matches this by exact
/// string equality against a `goNamed('lit')` nav expression's own quoted
/// first-arg source text, the same "match the source text verbatim, never
/// guess" doctrine `_normalizeAppPathsExpr` already uses.
class GoRouteDecl {
  GoRouteDecl(
    this.pathExpr,
    this.pageTypeName,
    this.line, {
    this.name,
    this.helperKey,
  });
  final String pathExpr;
  final String? pageTypeName;
  final int line;
  final String? name;
  // Mechanism (b) (0.5.0): set (to `functionName::pathExpr`, the
  // SAME compound key `_resolveHelperRoutes` writes to its result map) when
  // this GoRoute's `path:` leading identifier is the enclosing top-level
  // function's OWN parameter — a direct 1:1 link to the resolved helper
  // table, so two different GoRoutes that happen to share identical path
  // SOURCE TEXT (possible across different helper functions) are looked up
  // independently rather than through one shared path-keyed map. This key
  // alone does NOT make helper resolution unambiguous — `_resolveHelperRoutes`
  // additionally requires exactly one function DECLARATION and no
  // project-wide tear-off reference before trusting `functionName` at all
  // (the tear-off/unique-declaration gates, 0.5.0); see its doc comment for
  // the actual identity gates.
  final String? helperKey;
}

/// Mechanism (a) — route-constant substitution (0.5.0, gated by the
/// shadowing/reachability and cross-file-identity checks below): a
/// project-wide `constantName -> declarations` table built from top-level
/// variables and static class fields whose initializer is a bare dotted
/// chain (see `nav_resolution.dart`'s `looksLikeDottedChain`) — either
/// directly `AppPaths.`-rooted or referencing another such constant.
/// [file] is the DECLARING file — needed both to resolve which declaration a
/// same-named-but-different-file pair is (the cross-file-identity gate) and
/// to let a file using its OWN constant substitute even though the name is
/// also in its own `declaredNames` (the shadowing guard's self-reference
/// exception).
class ConstantDecl {
  ConstantDecl(this.name, this.rawInit, this.file);
  final String name;
  final String rawInit;
  final String file;
}

/// Mechanism (b) — monomorphic helper inlining (0.5.0): a top-level
/// function whose body contains `GoRoute(path: <param>...)` where the path
/// expression's leading identifier is one of the function's OWN parameters
/// (common shape: `GoRoute buildMenuSessionsRoute(Sessions sessionsRoute) {
/// return GoRoute(path: sessionsRoute.goRoute, ...); }`,
/// `lib/sessions/sessions_routes.dart`). [paramIndex] is the parameter's
/// zero-based POSITIONAL index — call-site matching is positional-only (see
/// `nav_resolution.dart`'s `_resolveHelperRoutes` REFUSAL gate), so a named
/// or reordered parameter at the call site can never line up with this by
/// accident. [pathExpr] is the GoRoute's raw path source text, substituted
/// at resolution time by replacing its leading `<param>` identifier with the
/// call-site argument.
class HelperRouteDecl {
  HelperRouteDecl(
    this.functionName,
    this.paramName,
    this.paramIndex,
    this.pathExpr,
    this.file,
  );
  final String functionName;
  final String paramName;
  final int paramIndex;
  final String pathExpr;
  // The file this helper FUNCTION is declared in (0.5.0) — needed
  // to require exactly one DECLARATION project-wide, not just one call
  // site: two unrelated top-level functions that happen to share a name
  // must never be conflated.
  final String file;
}

/// A project-wide call site of a bare top-level function call (`target ==
/// null`, syntax-only — same "can't tell function from constructor without
/// resolution" caveat as `GoRoute(...)` itself). Only POSITIONAL arguments
/// are recorded; [hasNamedArgs] flags a call that mixes in a named argument
/// so the REFUSAL gate in `nav_resolution.dart`'s `_resolveHelperRoutes` can
/// reject it outright (named/reordered params must never be matched
/// positionally — that would be guessing).
class HelperCallSite {
  HelperCallSite(
    this.functionName,
    this.positionalArgs,
    this.hasNamedArgs,
    this.file,
  );
  final String functionName;
  final List<String> positionalArgs;
  final bool hasNamedArgs;
  // The file this call site lives in (0.5.0) — the tear-off guard
  // needs to know the call site's OWN file to exempt it (along with the
  // declaring file) from the "referenced nowhere else" check.
  final String file;
}

/// Everything `engine.dart`'s `_parseFile` collects about one lib file:
/// symbols, wiring, navigation, and (transient, build-time-only) the
/// shadowing/identifier data the nav resolution refusal gates need.
class FileInfo {
  FileInfo(this.libPath);
  final String libPath;
  String role = 'misc';
  final List<String> internalImports = [];
  // target lib path -> 1-based line of the first import/export/part directive
  // that resolves to it (first occurrence wins for duplicate imports).
  final Map<String, int> importLines = {};
  // `export` directive targets only (a subset of internalImports, which also
  // gets these — see `_parseFile`) — the closure `_scanTestRefs` walks so a
  // test importing a barrel credits what the barrel re-exports too.
  final List<String> exports = [];
  final List<ProviderDecl> providerDecls = [];
  final List<ConstantDecl> constantDecls = [];
  final List<ClassDecl> classDecls = [];
  final List<SymbolRec> symbolRecs = [];
  // name/expr -> first line it appears at (insertion order == first-seen
  // order isn't relied on; callers sort by name where determinism matters).
  final Map<String, int> watches = {};
  final Map<String, int> reads = {};
  final Map<String, int> listens = {};
  // 3.0 Stage 2: `'<rel>|<provider>'` keys (e.g. `watches|homeProvider`) for
  // reader edges detected by the receiver's STATIC TYPE (element identity) vs
  // the name allow-list. Drives the edge `confidence`: resolved if present,
  // heuristic otherwise. A provider read via a Ref-typed receiver ANYWHERE in
  // the file marks the edge resolved (set membership, not first-occurrence).
  final Set<String> typedReaderKeys = {};
  // 3.0 Stage 2: `'<child>|<super>'` keys for implements/extends edges whose
  // supertype NamedType resolved to an element (resolved unit) - tags the
  // subtype edge `resolved` vs the name-matched `heuristic`.
  final Set<String> elementResolvedSupers = {};
  final Map<String, int> navigates = {};
  // GoRoute(...) declarations found anywhere in this file — Stage 4.
  final List<GoRouteDecl> goRoutes = [];
  // Mechanism (b): top-level functions declared in this file whose body
  // contains a GoRoute(path: <param>...) — see `HelperRouteDecl`.
  final List<HelperRouteDecl> helperRoutes = [];
  // Mechanism (b): every project-wide call site of a top-level function,
  // recorded regardless of whether that function is a route helper — the
  // call-site COUNT across the whole project is the refusal signal, so every
  // call must be seen before any helper is judged single-call-site.
  final List<HelperCallSite> helperCalls = [];
  // Number of test files whose resolved lib imports include this file —
  // populated by the Stage 1 test-reference pass, 0 for anything not scanned
  // (or when no test roots exist).
  int testRefs = 0;

  // 3.0 Stage 1 provenance: true if this file's extraction ran on a RESOLVED
  // analyzer unit (element model available), false if it fell back to
  // syntax-only parsing. Build-time only, not serialized yet — element-derived
  // edges that consume it land in Stage 2. ponytail: file-level flag, not
  // per-edge; per-edge resolved/elementId arrives when extraction diverges.
  bool resolved = false;

  // Transient (NOT serialized to code_graph.json — build-time-only inputs to
  // the substitution/inlining REFUSAL gates below). Populated by `_Visitor`
  // during `_parseFile`.
  //
  // Every identifier this file DECLARES anywhere: top-level vars/functions/
  // classes/enums/mixins, class/enum members, local variables, and
  // function/method/constructor parameters (including field-formal and
  // super-formal). Used to detect shadowing — a distant constant's name
  // colliding with a local/parameter name in the substituting file.
  final Set<String> declaredNames = {};
  // Every SimpleIdentifier lexeme referenced anywhere in this file (a token
  // set, deduped — same "candidate data" doctrine as the test-reference
  // pass's tokenization: a name mentioned in an unrelated context still
  // counts, so this is a conservative SUPERSET of real references, which is
  // exactly what a refusal gate wants — never under-count a possible
  // tear-off).
  final Set<String> identifierRefs = {};
}
