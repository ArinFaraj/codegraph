// Navigation resolution subsystem (extracted from engine.dart, pure refactor
// — zero behavior change). Owns Stage 4 / 0.5.0's three mechanisms for
// turning a `context.go`/`router.go` navigate expression into a resolved
// `navigates-to` file edge:
//   (a) route-constant substitution (`_resolveWithConstants` and friends)
//   (b) monomorphic helper inlining (`_resolveHelperRoutes`)
//   (c) library wrapper allowlist for `builder:`/`pageBuilder:` page-type
//       detection (`_firstCreatedType`) plus the `goNamed` name-table half
// plus the orchestration entry point `resolveNavigation` that builds the
// route/name tables `engine.dart`'s `build()` used to construct inline.
//
// Imports `engine.dart` for the shared registry types (`FileInfo`,
// `ClassDecl`, `Reachability`) rather than the reverse — those types are
// core-registry concerns engine.dart's non-nav code (provider resolution,
// markdown rendering) also depends on, so keeping them there and importing
// them here is the one-directional edge (no cycle).
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'engine.dart' show FileInfo;
import 'resolution.dart' show ClassResolver, Reachability;

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
/// chain (see `_dottedChainOnly`) — either directly `AppPaths.`-rooted or
/// referencing another such constant.
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
/// `_resolveHelperRoutes` REFUSAL gate), so a named or reordered parameter at
/// the call site can never line up with this by accident. [pathExpr] is the
/// GoRoute's raw path source text, substituted at resolution time by
/// replacing its leading `<param>` identifier with the call-site argument.
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
/// resolution" caveat as `GoRoute(...)` itself, see `_Visitor`). Only
/// POSITIONAL arguments are recorded; [hasNamedArgs] flags a call that mixes
/// in a named argument so the REFUSAL gate in `_resolveHelperRoutes` can
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

/// Normalizes an `AppPaths.<chain>` expression to its route-identity prefix
/// by stripping a single trailing `.goRoute`, `.path`, or `.name` accessor —
/// the only three ways a `go_router_paths`-based route table
/// (`AppPaths` in `lib/core/router/paths.dart`, Stage 4 discovery) turns a
/// route-chain object into the string GoRoute/context.go actually consume.
/// A `.query(...)` call (seen on some `context.go` targets, e.g.
/// `AppPaths.unlock.query({...}).path`) is stripped too — the query-string
/// tail doesn't change WHICH route it targets, only its parameters, so
/// dropping it is still non-guessing (same page, `query()` is documented as
/// building the same path with query params appended). Returns null when
/// `expr` isn't rooted at `AppPaths.` — the only pattern Stage 4 resolves;
/// everything else (local variables, params, `dest`, `unlockPath`, ...)
/// requires cross-function dataflow this syntax-only pass does not attempt.
final _appPathsTail = RegExp(
  r'^(AppPaths(?:\.[A-Za-z_][A-Za-z0-9_]*)+?)(?:\.query\([^()]*(?:\([^()]*\)[^()]*)*\))?\.(?:goRoute|path|name)$',
);
String? _normalizeAppPathsExpr(String expr) {
  final e = expr.trim();
  if (!e.startsWith('AppPaths.')) return null;
  final m = _appPathsTail.firstMatch(e);
  return m?.group(1);
}

/// A bare dotted-identifier-chain expression with NO trailing accessor and
/// no calls at all — the shape of a route-constant's own initializer, either
/// rooted directly at `AppPaths` (`final onboardingEnterUpnRoute =
/// AppPaths.language.info.enterUpn;`, a common
/// `lib/onboarding/routing/onboarding_routes.dart`) or at another constant
/// name (a 2nd-hop constant referencing a 1st-hop one). Capture accepts
/// either root — `_buildConstantTable` below is what actually requires the
/// chain to bottom out at `AppPaths.` before it's usable.
final _dottedChainOnly = RegExp(
  r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$',
);

/// True iff [init] is a bare dotted-identifier chain (see `_dottedChainOnly`
/// doc comment) — the shape a route constant's initializer must have to be
/// captured as a [ConstantDecl] by `engine.dart`'s `_collectConstantField`.
/// Exposed (not just the private regex) because the capture site — a
/// `_Visitor`/`_collect` concern reading class/top-level fields — stays in
/// engine.dart, while the shape rule itself belongs to nav's substitution
/// doctrine.
bool looksLikeDottedChain(String init) => _dottedChainOnly.hasMatch(init);

/// Project-wide `name -> declarations` table from every [ConstantDecl]
/// collected across all files. No refusal here — the refusal gates
/// (shadowing/reachability, and cross-file identity) are applied per-reader
/// at resolution time in `_resolveWithConstants`, since "is this name safe
/// to use" now depends on WHO is asking, not just how many distinct
/// declarations exist project-wide.
Map<String, List<ConstantDecl>> buildConstantTable(List<FileInfo> all) {
  final byName = <String, List<ConstantDecl>>{};
  for (final i in all) {
    for (final c in i.constantDecls) {
      byName.putIfAbsent(c.name, () => []).add(c);
    }
  }
  return byName;
}

/// The shadowing/reachability gate and the cross-file-identity gate —
/// shared by constant substitution here and by nothing else (helper
/// inlining has its own analogous gate in `_resolveHelperRoutes` since its
/// declaration shape — functions, not variables — differs).
///
/// Given [name] referenced (as the leading identifier of a dotted chain)
/// from [readerFile], returns the ONE raw initializer text to substitute, or
/// null to refuse. Refuses unless ALL hold:
///  - the name resolves via [table] (has >=1 declaration) at all;
///  - [readerFile]'s `declaredNames` does NOT contain [name] — UNLESS
///    [readerFile] is itself one of the declaring files (a file using its
///    own constant must still work: its `declaredNames` obviously contains
///    the name it declares). A local variable or parameter named like a
///    distant constant must never shadow-resolve to that constant.
///  - among the declarations of [name] that are import/export-reachable
///    from [readerFile] (self always reachable), there is EXACTLY ONE
///    DISTINCT `(file, rawInit)` pair. Two declarations that are
///    byte-identical (same file... impossible — declaringFile is part of
///    the key) or two DIFFERENT files both reachable and sharing the name
///    both refuse: file identity matters now, not just initializer text, so
///    two reachable same-name declarations from different files are never
///    silently coalesced even if their text happens to match.
String? _resolveConstantName(
  String name,
  String readerFile,
  Map<String, List<ConstantDecl>> table,
  Set<String> readerDeclaredNames,
  Reachability reach,
) {
  final decls = table[name];
  if (decls == null || decls.isEmpty) return null;
  final isOwnDecl = decls.any((d) => d.file == readerFile);
  if (readerDeclaredNames.contains(name) && !isOwnDecl) {
    return null; // shadowed by a local/parameter — never guess through it
  }
  final readerReach = reach.from(readerFile);
  final reachable = decls.where((d) => readerReach.contains(d.file)).toList();
  if (reachable.isEmpty) return null; // declaring file not import-reachable
  final distinctChains = <String>{
    for (final d in reachable) '${d.file} ${d.rawInit}',
  };
  if (distinctChains.length != 1) return null; // ambiguous — refuse
  return reachable.first.rawInit;
}

/// Substitutes a leading-identifier constant reference (seen from
/// [readerFile]) against [table] and re-normalizes, iterating to a fixpoint
/// (constants that reference other constants, e.g.
/// `onboardingEnterUpnRoute.livenessIntro.goRoute` chaining through a
/// further hop) capped at depth 3, cycle-guarded. Every hop is re-gated by
/// `_resolveConstantName` (shadowing + reachability + cross-file identity)
/// FROM [readerFile] — the reader identity does not change mid-chain, only
/// the identifier being substituted does. Returns the final
/// normalized `AppPaths.<chain>` root, or null if [expr] never resolves (not
/// `AppPaths.`-rooted even after substitution, a cycle, the cap is hit, or
/// any hop is refused).
String? resolveWithConstants(
  String expr,
  String readerFile,
  Map<String, List<ConstantDecl>> table,
  Set<String> readerDeclaredNames,
  Reachability reach,
) {
  var e = expr.trim();
  final seen = <String>{};
  for (var depth = 0; depth < 3; depth++) {
    final direct = _normalizeAppPathsExpr(e);
    if (direct != null) return direct;
    if (e.startsWith('AppPaths.')) return null; // rooted but unstrippable
    final dot = e.indexOf('.');
    final leading = dot < 0 ? e : e.substring(0, dot);
    final chain = _resolveConstantName(
      leading,
      readerFile,
      table,
      readerDeclaredNames,
      reach,
    );
    if (chain == null) return null;
    if (!seen.add(leading)) return null; // cycle guard
    final rest = dot < 0 ? '' : e.substring(dot);
    e = '$chain$rest';
  }
  return _normalizeAppPathsExpr(e);
}

/// Resolves every [HelperRouteDecl] across the project to a normalized
/// `AppPaths.<chain>` route (or leaves it unresolved), applying the REFUSAL
/// GATE (0.5.0):
///  (i) EXACTLY ONE function DECLARATION with this name project-wide
///      (`declFilesByName` — two top-level functions sharing a name, like two
///      same-named constants, means the name is dropped entirely: never
///      guess which one a call site meant);
///  (ii) EXACTLY ONE call site project-wide (`allCalls`, grouped by function
///      name) with no named arguments and enough positional args to reach
///      [HelperRouteDecl.paramIndex];
///  (iii) TEAR-OFF GUARD: the function name must not appear in
///      `identifierRefs` of any file OTHER than the declaring file and the
///      single call-site file — a bare `helperFn` reference elsewhere (most
///      plausibly a tear-off, `onTap: buildHelperRoute`, but the token match
///      can't distinguish that from any other mention) means a second use we
///      can't see the shape of might exist, so refuse rather than guess.
///      RESIDUAL LIMITATION: a tear-off written inside the declaring file or
///      the single call-site file itself is undetectable with this
///      file-granularity set — documented, not solved (see the cross-file
///      tear-off regression test, which this gate DOES catch). This residual
///      limitation is narrower than it looks for PRIVATE
///      helpers — a `_`-prefixed top-level function is only referenceable
///      (call OR tear-off) from within its own declaring file by Dart's own
///      privacy rules, so it is never inlined by mistake via a cross-file
///      tear-off; gate (iii) still applies to it (same-file tear-offs remain
///      the same undetectable residual case as for public helpers).
/// Two call sites, a named-arg call, a too-short arg list, a third-file
/// reference, or an unnormalizable argument all leave the helper's routes
/// unresolved — never guessed. A single helper function commonly declares
/// MULTIPLE `GoRoute`s (a parent plus nested `routes:` children, e.g.
/// `buildMenuSessionsRoute` — see
/// `lib/sessions/sessions_routes.dart`), each referencing the SAME parameter
/// with a different accessor tail (`sessionsRoute.goRoute`,
/// `sessionsRoute.deleteDevice.goRoute`, ...), so the result is keyed by
/// `functionName::pathExpr` (compound — a bare function-name key would let
/// the last-processed GoRoute silently overwrite the others' resolutions)
/// rather than by function name alone.
Map<String, String> _resolveHelperRoutes(
  List<HelperRouteDecl> helperRoutes,
  List<HelperCallSite> allCalls,
  Map<String, List<ConstantDecl>> constantTable,
  List<FileInfo> all,
  Reachability reach,
) {
  final callsByName = <String, List<HelperCallSite>>{};
  for (final c in allCalls) {
    callsByName.putIfAbsent(c.functionName, () => []).add(c);
  }
  // Gate (i): every distinct declaring file per function name — >1 means the
  // name is ambiguous project-wide, same doctrine as duplicate constants/
  // duplicate providers.
  final declFilesByName = <String, Set<String>>{};
  for (final h in helperRoutes) {
    declFilesByName.putIfAbsent(h.functionName, () => {}).add(h.file);
  }

  final result = <String, String>{};
  for (final h in helperRoutes) {
    if ((declFilesByName[h.functionName]?.length ?? 0) != 1) {
      continue; // gate (i): 2+ declarations sharing this name — refuse
    }
    final calls = callsByName[h.functionName];
    if (calls == null || calls.length != 1) continue; // 0 or >=2 call sites
    final call = calls.single;
    if (call.hasNamedArgs) continue; // named/reordered — refuse
    if (h.paramIndex >= call.positionalArgs.length) continue;

    // Gate (iii): tear-off guard — the function name must be referenced
    // nowhere else project-wide.
    final referencedElsewhere = all.any(
      (i) =>
          i.libPath != h.file &&
          i.libPath != call.file &&
          i.identifierRefs.contains(h.functionName),
    );
    if (referencedElsewhere) continue;

    final arg = call.positionalArgs[h.paramIndex];
    final argChain = resolveWithConstants(
      '$arg.goRoute',
      call.file,
      constantTable,
      // Look up the call site's own FileInfo for its declaredNames — `all`
      // is small enough project-wide that a linear scan here (once per
      // helper, not per file) is not worth indexing.
      all.firstWhere((i) => i.libPath == call.file).declaredNames,
      reach,
    );
    if (argChain == null) continue;
    // Substitute the leading `<param>` identifier in the GoRoute's own path
    // expression with the resolved call-site argument's chain, then
    // re-normalize the whole thing (handles `sessionsRoute.goRoute` ->
    // `AppPaths.menu.sessions.goRoute` directly, and a deeper accessor tail
    // like `sessionsRoute.deleteDevice.goRoute` the same way).
    final dot = h.pathExpr.indexOf('.');
    final rest = dot < 0 ? '' : h.pathExpr.substring(dot);
    final substituted = _normalizeAppPathsExpr('$argChain$rest');
    if (substituted != null) {
      result['${h.functionName}::${h.pathExpr}'] = substituted;
    }
  }
  return result;
}

/// Mechanism (c) — library wrapper allowlist (0.5.0): the EXACT set
/// of `Page<T>`-returning library wrapper types in `pageBuilder:`
/// bodies are observed to construct directly (Stage 4 + 0.5.0 discovery,
/// `lib/find_upn/routing/find_upn_routes.dart`'s `MaterialPage(child:
/// CardScannerPage(...))`, `lib/core/router/routes.dart`'s
/// `CustomTransitionPage(child: UnlockPage(...))`,
/// `lib/core/router/home_routes.dart`'s `ModalSheetPage(child:
/// DigitalIdPage())`). ONLY these — a project-declared wrapper (e.g. the
/// `AnalyticsWrapper` regression fixture) is NOT on this list and keeps
/// vetoing resolution entirely, exactly as before mechanism (c).
const _pageWrapperAllowlist = <String>{
  'MaterialPage',
  'CupertinoPage',
  'NoTransitionPage',
  'CustomTransitionPage',
  'ModalSheetPage',
};

/// True iff [name] looks like a Dart type name (leading uppercase) —
/// distinguishes a constructor-shaped bare call (`Foo(...)`) from a real
/// function call (`formatLabel(...)`) without needing type resolution.
/// Shared by nav's page-type detection here AND `engine.dart`'s `_Visitor`
/// (mechanism (b) call-site capture uses the same rule to decide whether a
/// bare call is a "real function call" candidate for `HelperCallSite`).
bool looksLikeTypeName(String name) =>
    name.isNotEmpty && name[0].toUpperCase() == name[0];

/// The page type for a `builder:`/`pageBuilder:` expression — ONLY when the
/// entire expression body is, itself, a bare top-level constructor-shaped
/// call: `Foo(...)` or `const Foo(...)`, optionally behind a single arrow
/// (`(c, s) => Foo(...)`). Never guesses: a block body (`(c, s) { ... }`) is
/// unconditionally unresolvable, even with a single trailing `return` —
/// syntax-only parsing can't tell an early-return `return Scaffold(...)`
/// (wrong: `Scaffold` isn't the page) from the real page apart from control
/// flow it doesn't analyze, so any block body stays null rather than risk a
/// wrong edge.
///
/// A wrapped result — `(c, s) => AnalyticsWrapper(child: Foo())` — is
/// unconditionally unresolvable UNLESS the top-level type is in
/// `_pageWrapperAllowlist` (mechanism (c)): for an allowlisted wrapper, the
/// SAME bare-top-level-call rule is applied recursively to its `child:`
/// argument instead of vetoing outright — `MaterialPage(child: Foo())`
/// resolves to `Foo`, and unwrapping repeats through further allowlisted
/// wrappers (`MaterialPage(child: CustomTransitionPage(child: Foo()))`) up
/// to depth 3. A NON-allowlisted top-level type (a project-declared wrapper)
/// still vetoes on ANY nested constructor-shaped call anywhere in its
/// arguments, exactly as before mechanism (c) — that regression fixture must
/// stay green. Within an allowlisted wrapper, any OTHER nested
/// constructor-shaped call outside the resolved `child:` path (e.g. inside a
/// `transitionsBuilder:` callback) still vetoes — only the `child:` chain is
/// ever trusted.
///
/// Syntax-only: no type resolution, so a `const Foo()`
/// (InstanceCreationExpression) and a bare `Foo()` (MethodInvocation with no
/// target — the common case, since analyzer can't disambiguate constructor
/// vs function calls without resolution) are both accepted; a
/// lowercase-first-letter call (a real function, e.g. `formatLabel(...)`) or
/// a named top-level function reference (`pageBuilder: digitalIdPageBuilder`)
/// is excluded to avoid false positives. Good enough to point at the page
/// file via [ClassResolver] (which refuses a same-named ambiguous page rather
/// than first-wins) — a wrapped/ambiguous result is dropped, not guessed — only
/// sometimes
/// null.
String? firstCreatedType(Expression builderExpr) {
  var expr = builderExpr;
  if (expr is FunctionExpression && expr.body is ExpressionFunctionBody) {
    expr = (expr.body as ExpressionFunctionBody).expression;
  } else if (expr is FunctionExpression) {
    // Block body (`{ ... }`, with or without an early return) — fails
    // closed: never resolve out of a block, see doc comment above.
    return null;
  }
  return _firstCreatedTypeUnwrapping(expr, 0);
}

/// The bare-top-level-call resolution core, recursing through allowlisted
/// wrappers' `child:` argument (mechanism (c)) up to [depth] 3. [depth] 0 is
/// the original (non-wrapper) call the plan already handled pre-0.5.0.
String? _firstCreatedTypeUnwrapping(Expression expr, int depth) {
  String? topLevelType;
  ArgumentList? topLevelArgs;
  if (expr is InstanceCreationExpression) {
    topLevelType = expr.constructorName.type.name.lexeme;
    topLevelArgs = expr.argumentList;
  } else if (expr is MethodInvocation &&
      expr.target == null &&
      looksLikeTypeName(expr.methodName.name)) {
    topLevelType = expr.methodName.name;
    topLevelArgs = expr.argumentList;
  }
  if (topLevelType == null || topLevelArgs == null) return null;

  if (_pageWrapperAllowlist.contains(topLevelType) && depth < 3) {
    // Allowlisted wrapper: find its `child:` argument (if any) and recurse
    // into it under the SAME rule, but only after confirming no OTHER
    // argument (i.e. anything that isn't the `child:` expression itself)
    // contains a nested constructor-shaped call — a construction inside
    // `transitionsBuilder:` or similar must still veto.
    Expression? child;
    for (final arg in topLevelArgs.arguments) {
      if (arg is NamedExpression && arg.name.label.name == 'child') {
        child = arg.expression;
      }
    }
    final nested = _NestedCreationVisitor();
    for (final arg in topLevelArgs.arguments) {
      final argExpr = arg is NamedExpression ? arg.expression : arg;
      if (identical(argExpr, child)) continue; // child: checked separately
      argExpr.accept(nested);
      if (nested.found) break;
    }
    if (nested.found) return null;
    if (child == null)
      return null; // wrapper with no child: — nothing to point at
    return _firstCreatedTypeUnwrapping(child, depth + 1);
  }

  // Non-allowlisted top-level type: any further constructor-shaped call
  // nested inside its OWN arguments (e.g. `child: AnalyticsWrapper(...)`'s
  // `Foo()`) means the top-level call is a wrapper, not the page — veto the
  // whole result rather than picking one.
  final nested = _NestedCreationVisitor();
  topLevelArgs.accept(nested);
  if (nested.found) return null;

  return topLevelType;
}

/// True iff any constructor-shaped call (`Foo(...)` / `const Foo(...)`) is
/// found anywhere inside the visited subtree — used to veto a top-level
/// `builder:` call whose arguments themselves construct another
/// registry-resolvable-shaped type (the wrapped-builder case).
class _NestedCreationVisitor extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    found = true;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && looksLikeTypeName(node.methodName.name)) {
      found = true;
      return;
    }
    super.visitMethodInvocation(node);
  }
}

/// The two navigation lookup tables `build()` feeds to `_writeGraph`:
/// resolved `AppPaths.<chain>` route -> declaring page file, and resolved
/// `goNamed` route name -> declaring page file.
class NavTables {
  NavTables(this.routeTable, this.nameTable);
  final Map<String, String> routeTable;
  final Map<String, String> nameTable;
}

/// Nav's own pipeline entry point: builds the helper-route table (mechanism
/// b), then the route-path and route-name tables `_writeGraph` resolves
/// `navigates` edges against. This is exactly the work `build()` used to
/// inline (the two loops turning `GoRoute`s into route->pageFile and
/// name->pageFile maps, plus the `_resolveHelperRoutes` call feeding the
/// first one) — moved here verbatim so `build()` reads as a plain pass-list.
NavTables resolveNavigation(
  List<FileInfo> all,
  Map<String, List<ConstantDecl>> constantTable,
  ClassResolver classResolver,
  Reachability reach,
) {
  // Mechanism (b): monomorphic helper inlining (0.5.0) — a
  // project-wide `functionName -> normalizedChain` table for every
  // single-call-site route helper. See `_resolveHelperRoutes` doc comment
  // for the refusal gate.
  final allHelperRoutes = [for (final i in all) ...i.helperRoutes];
  final allHelperCalls = [for (final i in all) ...i.helperCalls];
  final helperRouteTable = _resolveHelperRoutes(
    allHelperRoutes,
    allHelperCalls,
    constantTable,
    all,
    reach,
  );

  // Stage 4: route-path -> page-file table, built from every GoRoute(...)
  // whose `path:` normalizes via `_resolveWithConstants` (a bare
  // `AppPaths.<chain>` expression directly, or one reached through mechanism
  // (a)'s constant table) — OR, when the path's leading identifier is the
  // enclosing function's own parameter, via mechanism (b)'s
  // `helperRouteTable`, looked up by THIS GoRoute's own `helperKey` (a
  // direct 1:1 link set at capture time — see `GoRouteDecl.helperKey` doc
  // comment; NOT a path-text lookup, since one helper function commonly
  // declares multiple GoRoutes off the same parameter) — AND whose
  // builder/pageBuilder resolved a class type (via [ClassResolver], which
  // refuses an ambiguous same-named page rather than first-wins). `putIfAbsent`
  // in file-walk order decides which wins if >1 GoRoute ever shares one
  // normalized path (should not happen — routes are unique); determinism holds
  // because `_dartFiles` sorts the walk and roots append in fixed order.
  final routeTable = <String, String>{};
  for (final i in all) {
    for (final r in i.goRoutes) {
      var norm = resolveWithConstants(
        r.pathExpr,
        i.libPath,
        constantTable,
        i.declaredNames,
        reach,
      );
      if (norm == null && r.helperKey != null) {
        norm = helperRouteTable[r.helperKey];
      }
      if (norm == null || r.pageTypeName == null) continue;
      // Reader = this GoRoute's own declaring file: it constructs the page, so
      // it must import the page's file, which is what lets reachability pick
      // the right same-named class instead of first-wins (see [ClassResolver]).
      final pageFile = classResolver.fileFor(r.pageTypeName!, i.libPath);
      if (pageFile == null) continue;
      routeTable.putIfAbsent(norm, () => pageFile);
    }
  }

  // Mechanism (c), goNamed half: `name:` (quoted-string source text) ->
  // page-file, from every GoRoute(...) that declared one AND resolved a
  // page type — matched at resolution time against a `goNamed('lit')` nav
  // expression's own quoted first-arg source text by EXACT string equality
  // (see `GoRouteDecl.name` doc comment). REFUSAL GATE (0.5.0): a
  // `name:` declared by MORE THAN ONE GoRoute project-wide is dropped from
  // the table entirely — go_router itself requires route names to be
  // unique, so two GoRoutes sharing one is a project bug, but this tool
  // never guesses which declaration a `goNamed(...)` caller meant; first-wins
  // silently picking one (a naive earlier implementation) is exactly the kind
  // of wrong edge the doctrine forbids. Same principle as duplicate
  // constants/duplicate helper declarations.
  final nameCandidates = <String, Set<String>>{};
  for (final i in all) {
    for (final r in i.goRoutes) {
      if (r.name == null || r.pageTypeName == null) continue;
      final pageFile = classResolver.fileFor(r.pageTypeName!, i.libPath);
      if (pageFile == null) continue;
      nameCandidates.putIfAbsent(r.name!, () => {}).add(pageFile);
    }
  }
  final nameTable = <String, String>{
    for (final e in nameCandidates.entries)
      if (e.value.length == 1) e.key: e.value.single,
  };

  return NavTables(routeTable, nameTable);
}
