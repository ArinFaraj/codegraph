// Accurate Dart code-relationship extractor for AI navigation.
//
// Uses the REAL Dart analyzer parser (`package:analyzer`), so every Dart 3.x
// construct parses correctly. Unlike syntactic tree-sitter tools, references
// are *resolved against a whole-project registry*, so a provider is ONE
// canonical node — you can answer "who reads it?" — instead of a separate node
// per reader.
//
// It captures the relations that plain imports miss and that cost AI agents
// the most grep budget:
//   * Riverpod wiring   — provider declarations + ref.watch/read/listen edges
//   * Navigation        — context.go/push / router.go(...) targets
//   * Type graph        — extends / implements (resolved to declarations)
//   * Coupling          — imports crossing feature boundaries
//   * Symbols           — classes/enums/functions per file ("where is X?")
//
// Scans `lib/` plus every local package under `packages/*/lib` (auto-discovered
// from `packages/*/pubspec.yaml`). The host app's own package name is read from
// its pubspec.yaml, so `package:<self>/...` imports resolve on any project.
//
// Outputs:
//   * docs/maps/code_graph.json   — whole-project resolved graph (query CLI input)
//   * docs/maps/<area>.md         — human/agent-readable map per lib area/package
//   * docs/maps/INDEX.md          — area index
//
// CHANGELOG / decisions (the self-improving loop — see repo CHANGELOG.md):
//   Freshness = SessionStart hook (installed by `codegraph init`) + CI `check`
//   gate. REJECTED: per-edit (PostToolUse) regen — seconds of latency on every
//   edit for marginal freshness. Do NOT re-propose.
//   0.2.0: symbols are full records (kind/line/signature/doc/members via
//   signatures.dart) and wiring edges carry line numbers, so agents get API
//   surface without Reading files. REJECTED: MCP server mode (resident
//   tool-schema tokens dwarf per-call CLI cost — stay a CLI); LLM summaries
//   or git-churn counts in committed artifacts (nondeterminism breaks the
//   check() gate). Do NOT re-propose without new evidence.
//   0.3.0: typed model in model.dart (wire format frozen byte-identically);
//   code_graph.json untracked in hosts; docs/maps/notes/ is ONE ungated dir —
//   build must never write there, check must never diff it.
//   0.4.0: test-reference pass (testRefs on nodes — token/import match,
//   candidate data) + navigates-to edges (never guessed; partial by design).
//   Git and wall-clock stay VERB-ONLY (diff/impact/attention run on demand);
//   the build remains deterministic.
//   0.5.0: nav resolution via constant substitution / helper inlining /
//   wrapper allowlist — each gated by reachability + uniqueness + shadowing
//   refusals. NEVER trade a refusal gate for coverage; wrong edges are
//   blockers, missing edges are fine.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart' show DiagnosticType;
import 'package:analyzer/source/line_info.dart';

import 'attention.dart' as attention;
import 'markdown.dart' as markdown;
import 'model.dart';
import 'nav_resolution.dart';
import 'registry.dart';
import 'resolution.dart';

export 'registry.dart'
    show ConstantDecl, FileInfo, GoRouteDecl, HelperCallSite, HelperRouteDecl;
export 'resolution.dart'
    show ClassDecl, ClassResolver, ProviderDecl, ProviderResolver, Reachability;

const _generatedSuffixes = <String>[
  '.g.dart',
  '.freezed.dart',
  '.gr.dart',
  '.gen.dart',
  '.mocks.dart',
  '.config.dart',
];

// Most specific first so `NotifierProvider` is matched before `Provider`.
const _providerKinds = <String>[
  'AsyncNotifierProvider',
  'StreamNotifierProvider',
  'NotifierProvider',
  'ChangeNotifierProvider',
  'StateNotifierProvider',
  'StateProvider',
  'FutureProvider',
  'StreamProvider',
  'Provider',
];

String _role(String p) {
  bool has(String s) => p.contains(s);
  final base = p.split('/').last;
  if (p.endsWith('_controller.dart')) return 'controller';
  if (has('/provider/') || p.endsWith('_provider.dart')) return 'provider';
  if (has('/view/') || p.endsWith('_page.dart')) return 'view';
  if (has('/widget/') || has('/widgets/')) return 'widget';
  if (has('/use_cases/') || p.endsWith('_use_case.dart')) return 'use-case';
  if (has('/repository/') || p.endsWith('_repository.dart')) {
    return 'repository';
  }
  if (has('/hook/') || base.startsWith('use_')) return 'hook';
  if (has('/flow/')) return 'flow';
  if (has('/logic/')) return 'logic';
  if (has('/state/') || has('/model/')) return 'state/model';
  if (has('/routing/') || p.endsWith('_routes.dart')) return 'routing';
  if (has('/stub/')) return 'stub';
  if (has('/application/')) return 'application';
  return 'misc';
}

/// Method-invocation receivers treated as a Riverpod Ref/WidgetRef/
/// ProviderContainer for `watch`/`read`/`listen` edge detection. `ref`/`this.ref`
/// is the common local case; `_ref`/`this._ref`/`widgetRef` are the field-held-Ref
/// convention (interceptors, services, coordinators, notifiers); `container`/
/// `_container` is `ProviderContainer.read/listen` (bootstrap/dialog/dev code,
/// e.g. `container.read(authProvider.future)` in an extension) — all were
/// previously invisible. Every match still gates on the arg resolving to a real
/// provider downstream, so `container` (a common name) adds no guessed edges.
const _refReceivers = {
  'ref',
  'this.ref',
  '_ref',
  'this._ref',
  'widgetRef',
  'this.widgetRef',
  'container',
  'this.container',
  '_container',
  'this._container',
};

/// True iff [t] is a Riverpod Ref-like type - a `Ref`/`WidgetRef` (or any
/// subtype, e.g. `FooProviderRef`, `AutoDisposeRef`, all of which end in `Ref`)
/// or a `ProviderContainer`. Checked against the type itself and its full
/// supertype closure, so a concrete generated ref subtype still counts. Null
/// (syntax units have no static type) returns false - the name allow-list
/// handles those. Mirrors the `endsWith('Ref')` convention already used for
/// `*Ref` extension detection.
bool _isRefType(DartType? t) {
  if (t is! InterfaceType) return false;
  bool named(String? n) =>
      n != null && (n.endsWith('Ref') || n == 'ProviderContainer');
  if (named(t.element.name)) return true;
  for (final s in t.allSupertypes) {
    if (named(s.element.name)) return true;
  }
  return false;
}

String _baseProvider(String expr) {
  var e = expr.trim();
  final dot = e.indexOf('.');
  if (dot > 0) e = e.substring(0, dot);
  final paren = e.indexOf('(');
  if (paren > 0) e = e.substring(0, paren);
  return e;
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.info, this.lineInfo);
  final FileInfo info;
  final LineInfo lineInfo;

  // Mechanism (b): the enclosing TOP-LEVEL function's name + ordered
  // positional parameter names while visiting inside its body, null outside
  // any top-level function (e.g. a top-level `final routes = [...]` list
  // literal, or nested inside a class method — deliberately NOT tracked,
  // since the plan's discovered shape is a bare top-level function).
  String? _fnName;
  List<String> _fnParams = const [];

  // >0 while visiting inside an `extension … on Ref`/`on WidgetRef` (or any
  // `*Ref` type) body, where the implicit receiver of a bare `read`/`watch`/
  // `listen(provider)` call IS the Ref — e.g. an `extension on Ref`'s
  // `isAuthenticated` getter does `read(authProvider)` with no `ref.` prefix.
  // Those bare reads were invisible (no explicit receiver), under-reporting a
  // whole class of app-wide provider readers (benchmark: rel-auth completeness).
  int _refExtensionDepth = 0;

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final onType = node.onClause?.extendedType.toSource() ?? '';
    final name = onType.split('<').first.trim();
    final isRefLike = name.endsWith('Ref');
    if (isRefLike) _refExtensionDepth++;
    super.visitExtensionDeclaration(node);
    if (isRefLike) _refExtensionDepth--;
  }

  // --- declaredNames / identifierRefs (shadowing + tear-off gate infra) ---

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    info.identifierRefs.add(node.name);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    info.declaredNames.add(node.name.lexeme);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    // Covers simple/field-formal/super-formal/function-typed params (and
    // defaulted variants of each) in one pass — `FormalParameter.name` is
    // declared on the shared base type and `DefaultFormalParameter` forwards
    // it to the wrapped parameter, so no per-shape unwrapping is needed.
    for (final p in node.parameters) {
      final n = p.name?.lexeme;
      if (n != null) info.declaredNames.add(n);
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    info.declaredNames.add(node.namePart.toSource().split('<').first.trim());
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    info.declaredNames.add(node.name.lexeme);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    info.declaredNames.add(node.namePart.toSource().split('<').first.trim());
    super.visitEnumDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    info.declaredNames.add(node.name.lexeme);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    info.declaredNames.add(node.name.lexeme);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final n = node.name?.lexeme;
    if (n != null) info.declaredNames.add(n);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    info.declaredNames.add(node.name.lexeme);
    final savedName = _fnName;
    final savedParams = _fnParams;
    _fnName = node.name.lexeme;
    _fnParams = [
      for (final p in node.functionExpression.parameters?.parameters ??
          const <FormalParameter>[])
        p.name?.lexeme ?? '',
    ];
    super.visitFunctionDeclaration(node);
    _fnName = savedName;
    _fnParams = savedParams;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = node.methodName.name;
    // `realTarget` (not `target`) so cascade sections resolve their receiver:
    // `ref..listen(p)..read(q)` has a null `target` on each section but a
    // `realTarget` of `ref` — missing those under-reported keep-alive readers
    // (e.g. `..listen(deviceTokenProvider, (_, _) {})` in a lifecycle handler,
    // flagged zero-consumer). Bare calls in a `*Ref` extension stay null (no
    // cascade, no target) and fall through to the `_refExtensionDepth` branch;
    // the `_refReceivers` gate still blocks cascades on non-ref receivers.
    final target = node.realTarget?.toSource();
    final args = node.argumentList.arguments;
    final line = lineOf(lineInfo, node.offset);

    // Riverpod Ref/WidgetRef receivers. A local `ref` is the common case, but
    // classes that hold a Ref in a FIELD (interceptors, services, coordinators,
    // repositories, notifiers) call through `_ref`/`this._ref`/`widgetRef` —
    // and missing those silently under-reported EVERY provider's readers. Found
    // by an A/B eval: `_ref.read(authProvider)` in an HTTP interceptor's
    // siblings (router redirect facts) was invisible to `readers`.
    // The arg still resolves to a real provider downstream (unknown names fall
    // through to `edgeFieldsFor`'s external handling exactly as before), so
    // broadening the receiver adds real edges, not guesses. `_baseProvider`
    // already strips `.future`/`.notifier`/`.select`/family args.
    // Explicit Ref receiver (`ref`/`_ref`/`widgetRef`/…) OR a BARE call whose
    // implicit receiver is the Ref because we're inside a `*Ref` extension body.
    // Both still gate on the arg resolving to a real provider downstream, so no
    // unrelated bare `read()` becomes an edge.
    // 3.0 Stage 2: on a RESOLVED unit the receiver's static type settles this by
    // identity - any receiver whose type is (a subtype of) a Ref/WidgetRef/
    // ProviderContainer is a reader, whatever it is NAMED. This catches renamed
    // parameters (`void f(Ref r) => r.watch(p)`), aliases (`final x = ref`),
    // and getters returning a Ref - all invisible to the name allow-list. On a
    // syntax unit staticType is null, so it falls back to the allow-list
    // unchanged (resolved is a strict superset, never fewer edges).
    final typedRef = _isRefType(node.realTarget?.staticType);
    final refScoped = typedRef ||
        _refReceivers.contains(target) ||
        (target == null && _refExtensionDepth > 0);
    if (refScoped && args.isNotEmpty) {
      final p = _baseProvider(args.first.toSource());
      const relOf = {'watch': 'watches', 'read': 'reads', 'listen': 'listens'};
      final rel = relOf[method];
      if (rel != null) {
        (rel == 'watches'
                ? info.watches
                : rel == 'reads'
                    ? info.reads
                    : info.listens)
            .putIfAbsent(p, () => line);
        // Element-confirmed (receiver's static type is a Ref) -> the edge is
        // `resolved`; a name-only match stays `heuristic`.
        if (typedRef) info.typedReaderKeys.add('$rel|$p');
      }
    }

    const navMethods = {
      'go',
      'push',
      'replace',
      'pushReplacement',
      'goNamed',
      'pushNamed',
    };
    if (navMethods.contains(method) &&
        (target == 'context' || target == 'router') &&
        args.isNotEmpty) {
      info.navigates.putIfAbsent(args.first.toSource(), () => line);
    }

    // GoRoute(...) route declaration. In SYNTAX mode (no type resolution) a
    // constructor call with no `new`/`const` parses as a no-target
    // MethodInvocation, so it is caught here. In RESOLVED mode the analyzer
    // knows GoRoute is a class, so the SAME call parses as an
    // InstanceCreationExpression and is caught in visitInstanceCreationExpression
    // below — either way it routes through the one `_recordGoRoute`, so resolved
    // builds stay at least as complete as syntax (they lost every GoRoute-based
    // nav edge before this — found on the krdpass reference host, 2026-07-14).
    if (node.target == null && method == 'GoRoute') {
      _recordGoRoute(args, line);
    } else if (node.target == null && !looksLikeTypeName(method)) {
      // Mechanism (b) call-site capture: a bare (no-target) call to a
      // lowercase-first-letter name — i.e. a real function call, not a
      // constructor-shaped call (`looksLikeTypeName` already distinguishes
      // these for `firstCreatedType`, reused here for the same reason).
      // Recorded for EVERY such call project-wide, not just calls to known
      // helpers, because the call-site COUNT is the refusal signal and a
      // helper's declaration may be parsed after or before its call sites.
      final positional = <String>[];
      var hasNamed = false;
      for (final arg in args) {
        if (arg is NamedExpression) {
          hasNamed = true;
        } else {
          positional.add(arg.toSource());
        }
      }
      info.helperCalls.add(
        HelperCallSite(method, positional, hasNamed, info.libPath),
      );
    }

    super.visitMethodInvocation(node);
  }

  // A real constructor call. Only reachable in RESOLVED mode - the syntax
  // parser can't tell `GoRoute(...)` from a function call and emits a
  // MethodInvocation instead (handled in visitMethodInvocation). This is the
  // constructor-call twin so GoRoute declarations are captured under both.
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == 'GoRoute') {
      _recordGoRoute(
          node.argumentList.arguments, lineOf(lineInfo, node.offset));
    }
    super.visitInstanceCreationExpression(node);
  }

  // Shared GoRoute(...) extraction for both the method-call form (syntax) and
  // the constructor form (resolved). Reads the enclosing helper-function
  // context (`_fnName`/`_fnParams`) for mechanism (b) capture.
  void _recordGoRoute(List<Expression> args, int line) {
    String? pathExpr;
    Expression? builderExpr;
    String? nameExpr;
    for (final arg in args) {
      if (arg is! NamedExpression) continue;
      final argName = arg.name.label.name;
      if (argName == 'path') {
        pathExpr = arg.expression.toSource();
      } else if (argName == 'builder' || argName == 'pageBuilder') {
        builderExpr = arg.expression;
      } else if (argName == 'name') {
        nameExpr = arg.expression.toSource();
      }
    }
    if (pathExpr == null) return;
    // Mechanism (b) capture: the path's leading identifier is one of the
    // enclosing top-level function's OWN parameters. `helperKey` is a direct
    // 1:1 link from THIS GoRouteDecl to its resolved-table entry (see
    // `GoRouteDecl.helperKey` doc comment) - set here, not derived later from
    // path text, so a same-path-text lookup collision across two helper
    // functions is structurally avoided. The actual single-declaration /
    // single-call-site / no-tear-off safety comes from nav_resolution.dart's
    // `_resolveHelperRoutes` gates, not from this key shape alone.
    String? helperKey;
    final fnName = _fnName;
    if (fnName != null) {
      final leadDot = pathExpr.indexOf('.');
      final leading = leadDot < 0 ? pathExpr : pathExpr.substring(0, leadDot);
      final paramIndex = _fnParams.indexOf(leading);
      if (paramIndex >= 0) {
        info.helperRoutes.add(
          HelperRouteDecl(fnName, leading, paramIndex, pathExpr, info.libPath),
        );
        helperKey = '$fnName::$pathExpr';
      }
    }
    info.goRoutes.add(
      GoRouteDecl(
        pathExpr,
        builderExpr == null ? null : firstCreatedType(builderExpr),
        line,
        name: nameExpr,
        helperKey: helperKey,
      ),
    );
  }
}

void _collect(CompilationUnit unit, FileInfo info, LineInfo lineInfo) {
  SymbolRec symbolWithMembers(
    String name,
    String kind,
    int line,
    String sig, {
    String? doc,
    Iterable<ClassMember>? memberAst,
    String? ownerName,
  }) {
    final members = memberAst == null || ownerName == null
        ? null
        : renderMembers(memberAst, lineInfo, ownerName);
    final capped = members != null && members.any(isMemberCapTrailer);
    return SymbolRec(
      name,
      kind,
      line,
      sig,
      doc: doc,
      members: members,
      memberIndex:
          capped ? indexMemberNames(memberAst!, lineInfo, ownerName!) : null,
    );
  }

  for (final d in unit.declarations) {
    if (d is ClassDeclaration) {
      final name = d.namePart.toSource().split('<').first.trim();
      final supers = <String>[];
      void addSuper(NamedType t) {
        final s = t.toSource().split('<').first.trim();
        supers.add(s);
        // Resolved unit: the supertype NamedType carries its element, so this
        // edge is element-confirmed. Syntax unit: element is null -> heuristic.
        if (t.element != null) info.elementResolvedSupers.add('$name|$s');
      }

      final ext = d.extendsClause?.superclass;
      if (ext != null) addSuper(ext);
      for (final i in d.implementsClause?.interfaces ?? const []) {
        addSuper(i);
      }
      info.classDecls.add(ClassDecl(name, info.libPath, supers));
      info.symbolRecs.add(
        symbolWithMembers(
          name,
          d.mixinKeyword != null ? 'mixin' : 'class',
          lineOf(lineInfo, d.namePart.offset),
          renderClassSig(d),
          doc: renderDoc(d.documentationComment),
          memberAst: d.body.members,
          ownerName: name,
        ),
      );
      // Mechanism (a) capture, static-field half: a `static` field whose
      // initializer is a bare dotted chain (see nav_resolution.dart's
      // `looksLikeDottedChain`) — same rule as the top-level-variable half
      // below, scoped to `static` fields only (instance fields aren't a
      // route-identity constant).
      for (final m in d.body.members) {
        if (m is FieldDeclaration && m.isStatic) {
          _collectConstantField(m.fields, info);
        }
      }
    } else if (d is MixinDeclaration) {
      final name = d.name.lexeme;
      // A mixin's `on` clause (superclass constraints) and `implements`
      // clause are both stated, syntax-visible supertype facts - same
      // implements/extends edge path a ClassDeclaration uses below, so
      // `impls <Shape>` etc. also finds mixins that constrain/implement it.
      final supers = <String>[];
      for (final t in [
        ...?d.onClause?.superclassConstraints,
        ...?d.implementsClause?.interfaces,
      ]) {
        final s = t.toSource().split('<').first.trim();
        supers.add(s);
        if (t.element != null) info.elementResolvedSupers.add('$name|$s');
      }
      info.classDecls.add(ClassDecl(name, info.libPath, supers));
      info.symbolRecs.add(
        symbolWithMembers(
          name,
          'mixin',
          lineOf(lineInfo, d.name.offset),
          renderMixinSig(d),
          doc: renderDoc(d.documentationComment),
          memberAst: d.body.members,
          ownerName: name,
        ),
      );
    } else if (d is EnumDeclaration) {
      final name = d.namePart.toSource().split('<').first.trim();
      info.symbolRecs.add(
        symbolWithMembers(
          name,
          'enum',
          lineOf(lineInfo, d.namePart.offset),
          renderEnumSig(d),
          doc: renderDoc(d.documentationComment),
          memberAst: d.body.members,
          ownerName: name,
        ),
      );
    } else if (d is ExtensionDeclaration) {
      final name = d.name?.lexeme;
      if (name != null) {
        info.symbolRecs.add(
          symbolWithMembers(
            name,
            'ext',
            lineOf(lineInfo, d.offset),
            renderExtensionSig(d),
            doc: renderDoc(d.documentationComment),
            memberAst: d.body.members,
            ownerName: name,
          ),
        );
      }
    } else if (d is ExtensionTypeDeclaration) {
      final name = d.primaryConstructor.typeName.lexeme;
      // `implements` on an extension type is the same stated supertype fact
      // as a class's - wire it into the same edge path (see MixinDeclaration
      // above for the mixin half of this fix).
      final supers = <String>[];
      for (final i in d.implementsClause?.interfaces ?? const []) {
        final s = i.toSource().split('<').first.trim();
        supers.add(s);
        if (i.element != null) info.elementResolvedSupers.add('$name|$s');
      }
      info.classDecls.add(ClassDecl(name, info.libPath, supers));
      info.symbolRecs.add(
        symbolWithMembers(
          name,
          'ext-type',
          lineOf(lineInfo, d.primaryConstructor.typeName.offset),
          renderExtensionTypeSig(d),
          doc: renderDoc(d.documentationComment),
          memberAst: d.body.members,
          ownerName: name,
        ),
      );
    } else if (d is TypeAlias) {
      info.symbolRecs.add(
        SymbolRec(
          d.name.lexeme,
          'typedef',
          lineOf(lineInfo, d.name.offset),
          renderTypedefSig(d),
          doc: renderDoc(d.documentationComment),
        ),
      );
    } else if (d is FunctionDeclaration) {
      info.symbolRecs.add(
        SymbolRec(
          d.name.lexeme,
          'fn',
          lineOf(lineInfo, d.name.offset),
          renderFunctionSig(d),
          doc: renderDoc(d.documentationComment),
        ),
      );
    } else if (d is TopLevelVariableDeclaration) {
      for (final v in d.variables.variables) {
        final init = v.initializer?.toSource();
        if (init == null) continue;
        for (final k in _providerKinds) {
          // Match only an actual usage (constructor call or type arg), not a
          // string that merely mentions the kind name — e.g. a const list of
          // provider-kind strings must not be detected as a declaration.
          if (RegExp('\\b${RegExp.escape(k)}[<(.]').hasMatch(init)) {
            info.providerDecls.add(
              ProviderDecl(
                v.name.lexeme,
                info.libPath,
                k,
                init.contains('autoDispose'),
                lineOf(lineInfo, v.name.offset),
              ),
            );
            break;
          }
        }
      }
      // Mechanism (a) capture, top-level-variable half — see
      // `_collectConstantField` doc comment.
      _collectConstantField(d.variables, info);
    }
  }
  info.symbolRecs.sort((a, b) => a.line.compareTo(b.line));
}

/// Mechanism (a) capture (0.5.0): records a [ConstantDecl] for each
/// variable in [vars] whose initializer source is a bare dotted-identifier
/// chain (`looksLikeDottedChain` — no calls, no trailing accessor stripped
/// here; that happens at resolution time in `resolveWithConstants`). Covers
/// both `final onboardingEnterUpnRoute = AppPaths.language.info.enterUpn;`
/// (top-level) and a `static Path get details => ...` is NOT this shape (a
/// getter body, not a field initializer) — only plain `static final`/`static
/// const` FIELDS with a bare-chain initializer qualify, matching common
/// actually declares its route constants as.
void _collectConstantField(VariableDeclarationList vars, FileInfo info) {
  for (final v in vars.variables) {
    final init = v.initializer?.toSource().trim();
    if (init == null || !looksLikeDottedChain(init)) continue;
    info.constantDecls.add(ConstantDecl(v.name.lexeme, init, info.libPath));
  }
}

// File ids are repo-relative paths: `lib/...` for the app, `packages/<dir>/lib/...`
// for local packages, so one graph spans both.
String _libPathOf(String fsPath) =>
    fsPath.startsWith('./') ? fsPath.substring(2) : fsPath;

/// The host project's own package name (from its pubspec.yaml).
String _selfPackage() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) return '';
  return RegExp(
        r'^name:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync())?.group(1) ??
      '';
}

String? _pkgName(File pubspec) => RegExp(
      r'^name:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync())?.group(1);

/// Resolve a `path:` dependency value against the dir holding the pubspec that
/// declared it (handles `.`, `..`, and a `packages/x` relative form).
String _resolveRelativeDir(String baseDir, String rel) {
  final parts =
      baseDir == '.' || baseDir.isEmpty ? <String>[] : baseDir.split('/');
  for (final seg in rel.split('/')) {
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (seg != '.' && seg.isNotEmpty) {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// Local packages the app ACTUALLY depends on, discovered by following `path:`
/// dependencies (transitively) from the host pubspec. This is what `pub`
/// resolves, so it excludes stray copies under `packages/` — e.g. a
/// `foo_api_backup_<ts>/` whose pubspec still says `name: foo_api` would
/// otherwise shadow the real `foo_api` and silently redirect every
/// `package:foo_api/...` import to the backup. Host wins on any name collision.
Map<String, String> _pathDependencyPackages() {
  final map = <String, String>{};
  final seen = <String>{};
  final queue = <String>['pubspec.yaml'];
  final pathRe = RegExp(r'^\s+path:\s*(.+)$', multiLine: true);
  while (queue.isNotEmpty) {
    final pubspecPath = queue.removeLast();
    if (!seen.add(pubspecPath)) continue;
    final f = File(pubspecPath);
    if (!f.existsSync()) continue;
    final content = f.readAsStringSync();
    final baseDir = pubspecPath.contains('/')
        ? pubspecPath.substring(0, pubspecPath.lastIndexOf('/'))
        : '.';
    for (final m in pathRe.allMatches(content)) {
      var rel = m.group(1)!.split('#').first.trim();
      rel = rel.replaceAll(RegExp('''^['"]|['"]\$'''), '');
      if (rel.isEmpty) continue;
      final depDir = _resolveRelativeDir(baseDir, rel);
      final depPubspec = File('$depDir/pubspec.yaml');
      if (!depPubspec.existsSync()) continue;
      queue.add('$depDir/pubspec.yaml');
      final name = _pkgName(depPubspec);
      final lib = '$depDir/lib';
      if (name != null && Directory(lib).existsSync()) {
        map.putIfAbsent(name, () => _libPathOf(lib));
      }
    }
  }
  return map;
}

/// Local package name -> lib dir (e.g. `my_ui` -> `packages/my_ui/lib`).
///
/// Prefers `path:`-declared dependencies (what the app resolves). Falls back to
/// scanning every `packages/*/lib` only when the host declares no path deps
/// (an unusual layout), first-wins by sorted path on a name collision so the
/// result stays deterministic and a stray copy can't win.
Map<String, String> _localPackages() {
  final declared = _pathDependencyPackages();
  if (declared.isNotEmpty) return declared;

  final map = <String, String>{};
  final dir = Directory('packages');
  if (!dir.existsSync()) return map;
  // Sort by path: `listSync()` returns filesystem order, which is NOT stable
  // across machines. Package iteration order feeds node/edge emission order,
  // so an unsorted walk let two checkouts produce different code_graph.json.
  final packageDirs = dir.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final e in packageDirs) {
    final pubspec = File('${e.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final name = _pkgName(pubspec);
    final lib = '${e.path}/lib';
    if (name != null && Directory(lib).existsSync()) {
      map.putIfAbsent(name, () => _libPathOf(lib));
    }
  }
  return map;
}

/// Package-resolution context computed once per `build()` call: the host's
/// own package name plus the local package name -> lib dir map. Threaded as
/// a parameter through the parse passes so import resolution has no module
/// state.
typedef _PkgContext = ({String self, Map<String, String> packages});

// Repo-relative paths of files whose parse produced analyzer diagnostics
// during the most recent `build()` call - reset at the top of `build()`
// since tests call `build()` repeatedly in-process. Read once at the end of
// `build()` to print the "N files had parse errors" note.
final List<String> _parseErrorFiles = [];

String _resolveImport(String uri, String fileLibPath, _PkgContext pkgs) {
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return '';
    final pkg = rest.substring(0, slash);
    final path = rest.substring(slash + 1);
    if (pkg == pkgs.self) return 'lib/$path';
    final libDir = pkgs.packages[pkg];
    return libDir == null ? '' : '$libDir/$path';
  }
  if (!uri.contains(':')) {
    final dir = fileLibPath.substring(0, fileLibPath.lastIndexOf('/'));
    final parts = <String>[...dir.split('/')];
    for (final seg in uri.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.') {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }
  return '';
}

FileInfo _parseFile(File f, _PkgContext pkgs) {
  final parsed = parseString(
    content: f.readAsStringSync(),
    throwIfDiagnostics: false,
  );
  return _extractUnit(
      _libPathOf(f.path), parsed.unit, parsed.errors.isNotEmpty, pkgs);
}

/// Extract a [FileInfo] from a compilation unit. The unit may come from
/// syntax-only `parseString` (default) OR from a RESOLVED analyzer unit
/// (`build --resolved`, 3.0). The AST shape is identical either way; resolved
/// units additionally carry `staticType`/`element` data that Stage 2's
/// element-checked extractors consume. At Stage 1 the extraction is byte-for-
/// byte the same for both, so a resolved build and a syntax build produce an
/// identical graph — that equivalence is the Stage 1 correctness guarantee.
FileInfo _extractUnit(
    String libPath, CompilationUnit unit, bool hasErrors, _PkgContext pkgs) {
  final info = FileInfo(libPath)..role = _role(libPath);
  // A mid-edit file with a syntax error still parses a best-effort AST (that's
  // the point of throwIfDiagnostics: false - extraction shouldn't abort on one
  // bad file) but its extraction may be incomplete/wrong, so that must not
  // fold silently into the graph. Recorded here, surfaced once at the end of
  // `build()`.
  if (hasErrors) _parseErrorFiles.add(libPath);
  void addDep(String? uri, int line) {
    if (uri == null) return;
    final lib = _resolveImport(uri, libPath, pkgs);
    if (lib.isNotEmpty) {
      info.internalImports.add(lib);
      info.importLines.putIfAbsent(lib, () => line);
    }
  }

  // Imports, exports, parts — and their conditional configurations — are all
  // dependency edges: a file reached only via a barrel `export`, a library
  // `part`, or a conditional import must not be mistaken for an orphan.
  for (final dir in unit.directives) {
    final line = unit.lineInfo.getLocation(dir.offset).lineNumber;
    if (dir is ImportDirective) {
      addDep(dir.uri.stringValue, line);
      for (final c in dir.configurations) {
        addDep(c.uri.stringValue, line);
      }
    } else if (dir is ExportDirective) {
      addDep(dir.uri.stringValue, line);
      for (final c in dir.configurations) {
        addDep(c.uri.stringValue, line);
      }
      final lib = _resolveImport(dir.uri.stringValue ?? '', libPath, pkgs);
      if (lib.isNotEmpty) info.exports.add(lib);
    } else if (dir is PartDirective) {
      addDep(dir.uri.stringValue, line);
    }
  }
  _collect(unit, info, unit.lineInfo);
  unit.accept(_Visitor(info, unit.lineInfo));
  return info;
}

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !_generatedSuffixes.any((s) => f.path.endsWith(s)))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

/// Deterministic digest (FNV-1a 64) of every source input `build` reads: the
/// host pubspec plus the path and CONTENT of each scanned .dart file, using
/// the exact enumeration build uses. Content-based on purpose - identical
/// source always yields an identical value regardless of mtimes or checkout,
/// so storing it in code_graph.json keeps the byte-determinism doctrine (and
/// check()'s content-diff gate) intact. Queries compare this against the
/// stored `stats.sourceDigest` to detect a stale graph (see freshness.dart) -
/// the fix for the documented "stale graph returns a silent false negative"
/// trap.
int sourceDigest() {
  var h = 0xcbf29ce484222325;
  void mix(List<int> bytes) {
    for (final b in bytes) {
      h ^= b;
      h *= 0x100000001b3;
    }
  }

  void mixFile(File f) {
    mix(utf8.encode(f.path));
    mix(f.readAsBytesSync());
  }

  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync()) mixFile(pubspec);
  for (final root in ['lib', ..._localPackages().values]) {
    if (!Directory(root).existsSync()) continue;
    _dartFiles(root).forEach(mixFile);
  }
  return h;
}

/// Stat-only fast-path companion to [sourceDigest]: same FNV-1a 64 shape and
/// the exact same file enumeration, but mixes each file's path + length +
/// mtime (millisecondsSinceEpoch) instead of its content - no file reads, so
/// it is ~an order of magnitude cheaper on a large host. freshness.dart
/// compares it against `stats.statDigest` first and only falls back to the
/// content digest on mismatch, so the never-stale guarantee is unchanged.
///
/// NOT part of the determinism contract: mtimes vary across checkouts, so
/// byte-determinism of code_graph.json for identical source is intentionally
/// relaxed for this ONE stats key. check()'s git-diff gate is unaffected
/// because hosts gitignore code_graph.json (see the sourceDigest comment).
int statDigest() {
  var h = 0xcbf29ce484222325;
  void mix(List<int> bytes) {
    for (final b in bytes) {
      h ^= b;
      h *= 0x100000001b3;
    }
  }

  void mixFile(File f) {
    final s = f.statSync();
    mix(utf8
        .encode('${f.path}|${s.size}|${s.modified.millisecondsSinceEpoch}'));
  }

  final pubspec = File('pubspec.yaml');
  if (pubspec.existsSync()) mixFile(pubspec);
  for (final root in ['lib', ..._localPackages().values]) {
    if (!Directory(root).existsSync()) continue;
    _dartFiles(root).forEach(mixFile);
  }
  return h;
}

/// Test roots scanned by the Stage 1 test-reference pass, in fixed order (the
/// order doesn't affect output — every root's files are merged into one
/// sorted walk — but keeps the source readable).
const _testRoots = <String>['test', 'integration_test', 'patrol_test'];

/// Every declared provider name, split into tokens on the same rule used to
/// tokenize test source (`[A-Za-z_$][A-Za-z0-9_$]*`) — providers are always
/// already a single such token, so this is just the key set.
final _identifierToken = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');

/// Result of the test-reference pass: per-lib-file test-file counts and
/// per-provider-name test-file counts, plus the number of test files
/// scanned (`stats.testFiles`).
class TestRefs {
  TestRefs(this.fileTestRefs, this.providerTestRefs, this.testFileCount);
  final Map<String, int> fileTestRefs;
  final Map<String, int> providerTestRefs;
  final int testFileCount;
}

/// Stage 1.1: scans whichever of `test/`, `integration_test/`, `patrol_test/`
/// exist (same sorted `_dartFiles` walk as the lib pass — determinism carries
/// over unchanged). For each test file: resolved lib imports increment
/// `fileTestRefs[path]`; a single tokenization pass over the file's source
/// text, intersected with known provider names, increments
/// `providerTestRefs[name]` once per test FILE — but only when at least one
/// of that name's DECLARING files is in the test file's import+export
/// closure (the same `credited` set built below for file credits). A
/// provider name mentioned in a comment or string still counts if the
/// provider it names is declared in a file the test imports (directly or via
/// a barrel) — a far smaller false-positive class than a bare token match
/// anywhere in the repo's test suite. Ambiguous names (declared in more than
/// one file) are credited once the moment ANY declaring file is in the
/// closure, matching the existing per-name (not per-declaration) count.
///
/// A test file importing lib file B credits B AND every file in B's
/// transitive EXPORT closure (BFS over `export` directives only — `import`s
/// of B are not followed, matching `internalImports`' own import-vs-export
/// distinction). A test that imports `package:foo/foo.dart` (a barrel with
/// `export 'src/impl.dart';`) now credits `fileTestRefs` for BOTH the barrel
/// and `src/impl.dart`, so a barrel-only test no longer produces a false
/// "untested" on the file it re-exports. Multi-hop barrels (a barrel
/// exporting another barrel) are followed too, cycle-guarded; each file is
/// still credited at most once per test file even when reachable through more
/// than one barrel (dedup via the `resolvedImports`/closure set below).
///
/// Stage 3b: a `part` file carries no import directives of its own — a
/// Dart library's imports live in the library (`part of`) file and are
/// shared by every part. So a `part` file whose `part of 'uri.dart';` names
/// its parent by URI inherits the parent's resolved imports before the
/// closure gate is applied — a provider referenced only inside a part-file
/// test harness is credited via whatever the parent library imports. The
/// legacy by-NAME form (`part of some.library;`, no URI) is not resolvable
/// to a file without guessing, so it gets no inherited imports.
TestRefs _scanTestRefs(
  Map<String, Set<String>> providerDeclFiles,
  Map<String, List<String>> exportsByFile,
  _PkgContext pkgs,
) {
  final fileTestRefs = <String, int>{};
  final providerTestRefs = <String, int>{};
  var testFileCount = 0;

  // Memoized per-file transitive export closure (BFS, cycle-guarded) — a
  // barrel reachable from many test files only gets walked once.
  final closureCache = <String, Set<String>>{};
  Set<String> exportClosure(String start) {
    final cached = closureCache[start];
    if (cached != null) return cached;
    final seen = <String>{};
    final queue = <String>[start];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final next in exportsByFile[cur] ?? const []) {
        if (seen.add(next)) queue.add(next);
      }
    }
    closureCache[start] = seen;
    return seen;
  }

  // Pass A: parse every test file once and record its own resolved imports
  // plus (if it's a `part` file resolvable by URI) its parent library path.
  final records = <_TestFileRecord>[];
  for (final root in _testRoots) {
    if (!Directory(root).existsSync()) continue;
    for (final f in _dartFiles(root)) {
      testFileCount++;
      final source = f.readAsStringSync();
      final parsed = parseString(content: source, throwIfDiagnostics: false);
      final unit = parsed.unit;

      final testLibPath = _libPathOf(f.path);
      if (parsed.errors.isNotEmpty) _parseErrorFiles.add(testLibPath);
      final ownImports = <String>{};
      String? parentLib;
      for (final dir in unit.directives) {
        if (dir is ImportDirective) {
          final lib =
              _resolveImport(dir.uri.stringValue ?? '', testLibPath, pkgs);
          if (lib.isNotEmpty) ownImports.add(lib);
        } else if (dir is PartOfDirective) {
          final uri = dir.uri?.stringValue;
          if (uri != null) {
            final lib = _resolveImport(uri, testLibPath, pkgs);
            if (lib.isNotEmpty) parentLib = lib;
          }
          // by-name `part of` (dir.uri == null): not resolvable — no parent.
        }
      }
      records.add(_TestFileRecord(testLibPath, source, ownImports, parentLib));
    }
  }

  final importsByLib = <String, Set<String>>{
    for (final r in records) r.libPath: r.ownImports,
  };

  // Pass B: credit files/providers, seeding each record's closure walk with
  // its own imports PLUS its parent library's imports (part-file inheritance).
  for (final r in records) {
    final effectiveImports = <String>{
      ...r.ownImports,
      if (r.parentLib != null) ...?importsByLib[r.parentLib],
    };
    final credited = <String>{...effectiveImports};
    for (final lib in effectiveImports) {
      credited.addAll(exportClosure(lib));
    }
    for (final lib in credited) {
      fileTestRefs[lib] = (fileTestRefs[lib] ?? 0) + 1;
    }

    final tokens =
        _identifierToken.allMatches(r.source).map((m) => m.group(0)!).toSet();
    for (final name in tokens) {
      final declFiles = providerDeclFiles[name];
      if (declFiles != null && declFiles.any(credited.contains)) {
        providerTestRefs[name] = (providerTestRefs[name] ?? 0) + 1;
      }
    }
  }
  return TestRefs(fileTestRefs, providerTestRefs, testFileCount);
}

/// One scanned test file's own imports and (if it's a URI-form `part of`)
/// its parent library path — the seed data for Stage 3b's two-pass credit.
class _TestFileRecord {
  _TestFileRecord(this.libPath, this.source, this.ownImports, this.parentLib);
  final String libPath;
  final String source;
  final Set<String> ownImports;
  final String? parentLib;
}

/// `codegraph build [lib/<area>]` — regenerate graph + all area maps
/// (+ a scoped map when a directory is given).
void build(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final pkgs = _buildSetup();

  // Pass 1 (syntax): parse lib/ + every local package's lib/.
  final all = <FileInfo>[];
  for (final root in ['lib', ...pkgs.packages.values]) {
    for (final f in _dartFiles(root)) {
      all.add(_parseFile(f, pkgs));
    }
  }
  _emitBuild(all, positional, pkgs);
}

/// `codegraph build --resolved` (3.0 Stage 1) — same output as `build`, but
/// Pass 1 runs the analyzer's RESOLVED element model per file (element data
/// available to Stage 2 extractors) with a per-file fallback to syntax when a
/// file will not resolve. Requires the host's own `pub get` (a
/// `.dart_tool/package_config.json`); refuses with an instruction if absent
/// rather than silently degrading the whole build to syntax.
Future<void> buildResolved(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final pkgs = _buildSetup();
  if (!File('.dart_tool/package_config.json').existsSync()) {
    stderr.writeln(
      '--resolved needs resolved dependencies but no '
      '.dart_tool/package_config.json was found. Run: dart pub get '
      '(or flutter pub get), then: codegraph build --resolved',
    );
    exit(66);
  }
  final all = await _resolveFiles(['lib', ...pkgs.packages.values], pkgs);
  _emitBuild(all, positional, pkgs);
}

/// Shared build preamble: guard the package root and reset the per-run
/// parse-error accumulator, then compute the package-resolution context once.
_PkgContext _buildSetup() {
  if (!Directory('lib').existsSync()) {
    stderr.writeln('run from the package root (no lib/ here)');
    exit(66);
  }
  _parseErrorFiles.clear();
  return (self: _selfPackage(), packages: _localPackages());
}

/// Pass 1 (resolved): drive [AnalysisContextCollection] over the host roots and
/// extract each file from its resolved unit; a file that fails resolution
/// (thrown error or a non-[ResolvedUnitResult]) falls back to syntax parsing
/// and is counted. Same deterministic `_dartFiles` enumeration as the syntax
/// pass, so node/edge order is unchanged.
Future<List<FileInfo>> _resolveFiles(
    List<String> roots, _PkgContext pkgs) async {
  final collection = AnalysisContextCollection(
    includedPaths: [for (final r in roots) File(r).absolute.path],
  );
  final all = <FileInfo>[];
  var fellBack = 0;
  for (final root in roots) {
    for (final f in _dartFiles(root)) {
      final abs = f.absolute.path;
      final libPath = _libPathOf(f.path);
      ResolvedUnitResult? r;
      try {
        final unit = await collection
            .contextFor(abs)
            .currentSession
            .getResolvedUnit(abs);
        if (unit is ResolvedUnitResult) r = unit;
      } catch (_) {
        // Any resolution failure -> syntax fallback for THIS file only.
      }
      if (r != null) {
        // Match the syntax path's meaning of "extraction may be incomplete":
        // SYNTACTIC errors only (a best-effort AST). Semantic errors from
        // absent external deps (e.g. an unresolved `package:` import) leave the
        // AST complete, so they must NOT trip the parse-error note.
        final hasError = r.diagnostics.any(
            (d) => d.diagnosticCode.type == DiagnosticType.SYNTACTIC_ERROR);
        all.add(_extractUnit(libPath, r.unit, hasError, pkgs)..resolved = true);
      } else {
        fellBack++;
        all.add(_parseFile(f, pkgs)); // resolved stays false
      }
    }
  }
  stderr.writeln(
    'resolved ${all.length - fellBack}/${all.length} files'
    '${fellBack > 0 ? ' ($fellBack fell back to syntax)' : ''}',
  );
  return all;
}

/// Everything after Pass 1: registries, resolvers, test-reference scan, nav
/// resolution, graph + markdown emission. Shared verbatim by the syntax and
/// resolved build paths (they differ only in how `all` was produced).
void _emitBuild(List<FileInfo> all, List<String> positional, _PkgContext pkgs) {
  // Group by name (not last-write-wins) so shared names survive to the
  // resolver below; see CHANGELOG: duplicate provider name misattribution.
  final providerDeclsByName = <String, List<ProviderDecl>>{};
  final classDeclsByName = <String, List<ClassDecl>>{};
  for (final i in all) {
    for (final p in i.providerDecls) {
      providerDeclsByName.putIfAbsent(p.name, () => []).add(p);
    }
    for (final c in i.classDecls) {
      classDeclsByName.putIfAbsent(c.name, () => []).add(c);
    }
  }

  final reach = Reachability({
    for (final i in all) i.libPath: i.internalImports,
  });
  final resolver = ProviderResolver(providerDeclsByName, reach);
  // Class-name resolution now mirrors the provider resolver: ambiguous names
  // (declared in >1 file) refuse-or-narrow instead of first-wins — see
  // [ClassResolver]. Shared by nav page resolution and the type edges below.
  final classResolver = ClassResolver(classDeclsByName, reach);

  // Markdown's cross-reference section wants a name -> declaration lookup, but
  // an uncertain "declared in X" pointer is worse than none, so ambiguous
  // names are omitted here (they still show under each file's own "providers
  // declared here", which never needed this map).
  final providerRegistry = <String, ProviderDecl>{
    for (final entry in providerDeclsByName.entries)
      if (!resolver.ambiguousNames.contains(entry.key))
        entry.key: entry.value.single,
  };

  // Pass 2: scan test roots (test/, integration_test/, patrol_test/) for
  // resolved-import and token-match references — see `_scanTestRefs`.
  final exportsByFile = {for (final i in all) i.libPath: i.exports};
  final providerDeclFiles = <String, Set<String>>{
    for (final e in providerDeclsByName.entries)
      e.key: {for (final p in e.value) p.file},
  };
  final testRefs = _scanTestRefs(providerDeclFiles, exportsByFile, pkgs);
  for (final i in all) {
    i.testRefs = testRefs.fileTestRefs[i.libPath] ?? 0;
  }

  // Mechanism (a): project-wide route-constant table (0.5.0) — see
  // `buildConstantTable` doc comment for the refusal gate.
  final constantTable = buildConstantTable(all);

  // Nav's own pipeline (mechanisms (b) + Stage 4 + mechanism (c) goNamed
  // half) — see `resolveNavigation` doc comment in nav_resolution.dart.
  final navTables = resolveNavigation(all, constantTable, classResolver, reach);

  final written = _writeGraph(
    all,
    resolver,
    classResolver,
    testRefs.providerTestRefs,
    testRefs.testFileCount,
    navTables.routeTable,
    constantTable,
    navTables.nameTable,
    reach,
  );
  final graph = written.graph;
  stderr.writeln(
    'nav resolution: ${written.navResolved}/${written.navTotal} '
    'navigate edges resolved',
  );
  attention.writeAttentionMd(graph);
  stderr.writeln('wrote docs/maps/ATTENTION.md');

  // Project-wide reader counts (watches+reads+listens occurrences, by
  // provider name) — used by every area map's Summary section. Computed once
  // here rather than per-map so a provider's count reflects the WHOLE
  // project, not just the area it's declared in.
  final readerCounts = <String, int>{};
  for (final i in all) {
    for (final name in [
      ...i.watches.keys,
      ...i.reads.keys,
      ...i.listens.keys
    ]) {
      readerCounts[name] = (readerCounts[name] ?? 0) + 1;
    }
  }

  // Emit a scoped markdown map if a directory was requested.
  if (positional.isNotEmpty) {
    final dir = positional.first;
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    final scoped = all.where((i) => i.libPath.startsWith(prefix)).toList();
    final name = dir.split('/').where((s) => s.isNotEmpty).last;
    final outPath = 'docs/maps/$name.md';
    markdown.writeMarkdown(
      scoped,
      providerRegistry,
      prefix,
      outPath,
      readerCounts,
    );
    stderr.writeln('wrote $outPath (${scoped.length} files)');
  }

  markdown.writeAllAreaMaps(all, providerRegistry, readerCounts);

  // A file with a syntax error still parses best-effort, so its extraction
  // may be incomplete or wrong without any other signal - this is the one
  // place that gets surfaced. Deterministic (sorted), stderr only, no effect
  // on the graph itself.
  if (_parseErrorFiles.isNotEmpty) {
    final sorted = _parseErrorFiles.toSet().toList()..sort();
    stderr.writeln(
      'note: ${sorted.length} files had parse errors - their extraction may '
      'be incomplete (worst: ${sorted.first})',
    );
  }
}

// Scope for both check() git diff calls: docs/maps/ excluding docs/maps/notes/
// (the ungated knowledge sidecar, Stage 3 — the exclusion lands now so check
// never gates on it once that dir exists).
const _checkDiffScope = ['docs/maps/', ':(exclude)docs/maps/notes/'];

/// `codegraph check` — regen, then fail if committed docs/maps/ drifted.
/// Untracked maps that have never been committed are ignored, so this does not
/// false-fail before first commit.
int check() {
  build(const []);
  final quiet = Process.runSync('git', [
    'diff',
    '--quiet',
    '--',
    ..._checkDiffScope,
  ]);
  if (quiet.exitCode != 0) {
    stderr.writeln('ERROR: docs/maps/ is stale. Run: codegraph build');
    final stat = Process.runSync('git', [
      '--no-pager',
      'diff',
      '--stat',
      '--',
      ..._checkDiffScope,
    ]);
    stderr.write(stat.stdout);
    return 1;
  }
  stdout.writeln('code graph is up to date.');
  return 0;
}

// Returns the graph plus the Stage 4 prototype metric (`nav resolution: X/Y
// navigate edges resolved`, printed once per `build()` call in `build()`
// above) - locals threaded back through the return value, not module state.
({Graph graph, int navResolved, int navTotal}) _writeGraph(
  List<FileInfo> all,
  ProviderResolver resolver,
  ClassResolver classResolver,
  Map<String, int> providerTestRefs,
  int testFileCount,
  Map<String, String> routeTable,
  Map<String, List<ConstantDecl>> constantTable,
  Map<String, String> nameTable,
  Reachability reach,
) {
  var navResolvedCount = 0;
  var navResolvedTotal = 0;
  final nodes = <GraphNode>[];
  final edges = <GraphEdge>[];

  for (final i in all) {
    final symbols = i.symbolRecs.toList()
      ..sort((a, b) => a.line.compareTo(b.line));
    nodes.add(
      GraphNode.file(
        id: 'file:${i.libPath}',
        role: i.role,
        label: i.libPath.split('/').last,
        symbols: symbols,
        testRefs: i.testRefs,
      ),
    );
  }
  for (final decls in resolver.declsByName.values) {
    for (final p in decls) {
      nodes.add(
        GraphNode.provider(
          id: resolver.nodeIdFor(p),
          name: p.name,
          providerType: p.kind,
          autoDispose: p.autoDispose,
          declaredIn: p.file,
          line: p.line,
          ambiguous: resolver.ambiguousNames.contains(p.name),
          // Ambiguous providers: the token-match count can't distinguish
          // which declaration a test file meant, so (per the plan) the same
          // count attaches to EVERY declaration of that name.
          testRefs: providerTestRefs[p.name] ?? 0,
        ),
      );
    }
  }

  for (final i in all) {
    final src = 'file:${i.libPath}';
    for (final imp in i.internalImports.toSet()) {
      edges.add(GraphEdge(
          src: src,
          rel: 'imports',
          dst: 'file:$imp',
          line: i.importLines[imp]));
    }
    void provEdges(Map<String, int> m, String rel) {
      for (final entry in m.entries) {
        final fields = resolver.edgeFieldsFor(i.libPath, entry.key);
        edges.add(
          GraphEdge(
            src: src,
            rel: rel,
            dst: fields['dst'] as String,
            external: fields['external'] == true,
            ambiguous: fields['ambiguous'] == true,
            candidates: (fields['candidates'] as List?)?.cast<String>(),
            line: entry.value,
            confidence: i.typedReaderKeys.contains('$rel|${entry.key}')
                ? 'resolved'
                : 'heuristic',
          ),
        );
      }
    }

    provEdges(i.watches, 'watches');
    provEdges(i.reads, 'reads');
    provEdges(i.listens, 'listens');
    for (final p in i.providerDecls) {
      edges.add(
        GraphEdge(
          src: src,
          rel: 'declares',
          dst: resolver.nodeIdFor(p),
          line: p.line,
        ),
      );
    }
    for (final entry in i.navigates.entries) {
      navResolvedTotal++;
      final norm = resolveWithConstants(
        entry.key,
        i.libPath,
        constantTable,
        i.declaredNames,
        reach,
      );
      // Mechanism (c), goNamed half: when path-based resolution didn't
      // match, try the name table by EXACT quoted-string equality — the nav
      // expression's own source text is `entry.key` (e.g. `'lit'` from
      // `goNamed('lit')`), so this only ever fires for a literal-string
      // first arg, never a variable (the identity match doesn't need
      // `resolveWithConstants`-style substitution: a `goNamed(...)` name
      // isn't an `AppPaths.` chain).
      final pageFile =
          (norm == null ? null : routeTable[norm]) ?? nameTable[entry.key];
      edges.add(
        GraphEdge(
          src: src,
          rel: 'navigates',
          dst: 'route:${entry.key}',
          line: entry.value,
          unresolved: pageFile == null,
        ),
      );
      if (pageFile != null) {
        navResolvedCount++;
        edges.add(
          GraphEdge(
            src: src,
            rel: 'navigates-to',
            dst: 'file:$pageFile',
            line: entry.value,
          ),
        );
      }
    }
    for (final c in i.classDecls) {
      for (final s in c.supertypes) {
        final fields = classResolver.typeEdgeFieldsFor(i.libPath, s);
        edges.add(GraphEdge(
          src: src,
          rel: 'implements/extends',
          dst: fields['dst'] as String,
          detail: '${c.name} -> $s',
          ambiguous: fields['ambiguous'] == true,
          candidates: (fields['candidates'] as List?)?.cast<String>(),
          childName: c.name,
          parentName: s,
          confidence: i.elementResolvedSupers.contains('${c.name}|$s')
              ? 'resolved'
              : 'heuristic',
        ));
      }
    }
  }

  final graph = Graph(
    // No wall-clock timestamp here on purpose: `check()` content-diffs this
    // file against the committed copy as a CI staleness gate, so a field
    // that changes on every build with unchanged source would make it fail
    // on every real CI run, regardless of drift. Git history already answers
    // "when was this generated" (caught while dogfooding, 2026-07-02).
    libRoot: 'lib',
    stats: {
      'format': graphFormatVersion,
      'files': all.length,
      'providers': resolver.declsByName.length,
      'edges': edges.length,
      // Content digest of the source this graph was built from - queries use
      // it to detect staleness and auto-rebuild (freshness.dart). Additive,
      // deterministic (no wall clock; see the comment above). Inserted BEFORE
      // testFiles so both pinned positions hold (format first, testFiles last).
      'sourceDigest': sourceDigest(),
      // Stat-only digest (path + length + mtime) for the freshness fast path.
      // Mtimes vary across checkouts, so this ONE key intentionally relaxes
      // byte-determinism of code_graph.json for identical source; check()'s
      // git-diff gate is unaffected because hosts gitignore code_graph.json.
      // Still inserted BEFORE testFiles (format first, testFiles last hold).
      'statDigest': statDigest(),
      'testFiles': testFileCount,
    },
    nodes: nodes,
    edges: edges,
  );
  final out = File('docs/maps/code_graph.json');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(graph.toJson()),
  );
  stderr.writeln(
    'wrote docs/maps/code_graph.json '
    '(${all.length} files, ${resolver.declsByName.length} providers, ${edges.length} edges)',
  );
  // Honesty metric (3.0 Stage 2): how many reader edges are element-resolved vs
  // name-matched. A syntax build is 0 resolved; a resolved build trends toward
  // all - the fraction is a quality signal that improves as extractors go
  // element-checked.
  void reportConfidence(String label, bool Function(GraphEdge) pick) {
    final es = edges.where(pick).toList();
    if (es.isEmpty) return;
    final resolved = es.where((e) => e.confidence == 'resolved').length;
    stderr.writeln('$label: $resolved/${es.length} element-resolved');
  }

  reportConfidence('reader edges', (e) => providerConsumerRels.contains(e.rel));
  reportConfidence('subtype edges', (e) => e.rel == 'implements/extends');
  return (
    graph: graph,
    navResolved: navResolvedCount,
    navTotal: navResolvedTotal,
  );
}
