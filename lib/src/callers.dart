// `codegraph callers <Symbol>` / `refs <Symbol>` — symbol-precise call sites.
//
// The single most-requested missing capability across every eval round: `find`
// gives a symbol's DECLARATION, `readers` gives PROVIDER edges, `impact` gives
// WHOLE-FILE blast radius — none answers "who calls THIS method?" (`revokeSession`,
// `handleResume`, …), which every refactor/debug/trace task forced to grep.
//
// This is an on-demand AST scan (like `skeleton`, no graph bloat): it parses the
// graph's files PLUS the test roots (a signature change breaks tests too — those
// dirs are outside the graph) and matches call sites / references by NAME. Being
// AST-based it beats grep: no comment/string false hits, and it distinguishes a
// CALL (`x()`) from a REFERENCE (tear-off / type / switch case). Syntax-only, so
// matching is by name — for an ambiguous name it reports how many declarations
// exist so the agent knows the list spans them.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import 'analysis_env.dart';
import 'cli_util.dart';
import 'freshness.dart';
import 'model.dart';
import 'progress.dart';
import 'refactor_index.dart';
import 'workspace_files.dart';

class _Hit {
  _Hit(this.file, this.line, this.kind, this.text);
  final String file;
  final int line;
  final String kind; // 'call' | 'ref'
  final String text; // trimmed source line
}

class _Finder extends RecursiveAstVisitor<void> {
  _Finder(this.symbol, this.lineInfo, this.file, this.lines, this.hits,
      this.refsMode);
  final String symbol;
  final LineInfo lineInfo;
  final String file;
  final List<String> lines; // source lines for context text
  final List<_Hit> hits;
  final bool refsMode;

  String _lineText(int line) =>
      (line >= 1 && line <= lines.length) ? lines[line - 1].trim() : '';

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == symbol) {
      final line = lineInfo.getLocation(node.methodName.offset).lineNumber;
      hits.add(_Hit(file, line, 'call', _lineText(line)));
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (refsMode && node.name == symbol) {
      final p = node.parent;
      // Skip the CALL name (already recorded as 'call') and declaration names
      // (the definition, not a use).
      final isCallName = p is MethodInvocation && identical(p.methodName, node);
      final isDeclName = (p is MethodDeclaration && identical(p.name, node)) ||
          (p is FunctionDeclaration && identical(p.name, node)) ||
          (p is VariableDeclaration && identical(p.name, node)) ||
          (p is NamedType); // don't double-list a type at its own decl site
      if (!isCallName && !isDeclName) {
        final line = lineInfo.getLocation(node.offset).lineNumber;
        hits.add(_Hit(file, line, 'ref', _lineText(line)));
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

/// `int run(List<String> args)` — `callers|refs <Symbol> [--json] [--budget N]`.
/// [caveat] false suppresses the trailing caveat line — `uses` (intent.dart)
/// delegates here and prints its own union caveat instead.
int run(List<String> args, {bool caveat = true}) {
  final verb = args.isNotEmpty ? args.first : 'callers';
  final refsMode = verb == 'refs';
  final positional = positionalArgs(args);
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: $verb <Symbol>');
    return 64;
  }
  final symbol = positional[1];

  final graph = loadFresh();
  if (graph == null) return 66;

  // Scope: every file the graph knows (lib/ + packages/*/lib) PLUS the test
  // roots (outside the graph — but a signature change breaks tests too).
  final paths = <String>{
    for (final n in graph.nodes)
      if (n.isFile) n.id.replaceFirst('file:', ''),
  };
  final files = <File>[
    for (final p in paths)
      if (File(p).existsSync()) File(p),
    ...dartFilesUnderTestRoots(workspaceTestRoots(paths)),
  ];

  final hits = <_Hit>[];
  for (final f in files) {
    final String content;
    try {
      content = f.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    // Cheap pre-filter: no textual occurrence → skip the parse entirely.
    if (!content.contains(symbol)) continue;
    final unit = parseString(content: content, throwIfDiagnostics: false).unit;
    final lines = content.split('\n');
    final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
    unit.accept(_Finder(symbol, unit.lineInfo, rel, lines, hits, refsMode));
  }

  // Declarations of this name — top-level symbols AND class/mixin/extension
  // members — so an ambiguous name is flagged (call sites span all same-named
  // declarations under syntax-only).
  final decls = graph.declarationsOf(symbol);

  // Rank: by containing file in-degree (desc), then file, then line.
  int inDeg(String file) => graph.inDeg['file:$file'] ?? 0;
  hits.sort((a, b) {
    final byDeg = inDeg(b.file).compareTo(inDeg(a.file));
    if (byDeg != 0) return byDeg;
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });

  if (asJson) {
    emitJson({
      ...envelope(verb, symbol),
      'declarations': decls,
      // Additive: flags the merged-by-name case (text mode prints a note).
      if (decls.length > 1) 'ambiguousDeclarations': decls.length,
      'count': hits.length,
      'hits': [
        for (final h in hits.take(budget))
          {'file': h.file, 'line': h.line, 'kind': h.kind, 'text': h.text},
      ],
      if (hits.length > budget) 'truncated': hits.length - budget,
    });
    return 0;
  }

  final callN = hits.where((h) => h.kind == 'call').length;
  final refN = hits.length - callN;
  final header = refsMode
      ? 'references to $symbol — $callN calls + $refN other refs'
      : 'callers of $symbol — $callN call sites';
  final out = <String>[header];
  if (decls.length > 1) {
    out.add('  (note: $symbol has ${decls.length} declarations — '
        'sites match by name across all of them)');
  }
  if (hits.isEmpty) {
    out.add(decls.isNotEmpty
        ? '  (declared at ${decls.join(', ')} but no sites found — '
            'try `refs $symbol` for non-call references)'
        : '  (none — ${freshnessClause(graph.stats['files'] ?? 0)}; '
            'try `find $symbol`, or check the exact name)');
  }
  for (final h in hits) {
    final k = h.kind == 'ref' ? ' [ref]' : '';
    out.add('  ${h.file}:${h.line}$k  ${h.text}');
  }
  emit(out, budget, hint: 'raise --budget ${hits.length}');
  if (caveat) emitCaveats(verb);
  return 0;
}

// --- Element-precise resolved path (3.0 Stage 2) --------------------------
// Syntax-only `callers` matches by NAME, so `callers build` lumps EVERY widget's
// `build()` together. The resolved path resolves each call/ref to its declaring
// element and ATTRIBUTES it to the real target (`HomePage.build` vs
// `SettingsPage.build`), so a refactor of one specific method sees only its own
// sites. Opt-in via `--resolved`; normally served from the persistent semantic
// index, with a fresh whole-context analyzer walk as the compatibility fallback.

class _RHit {
  _RHit(this.file, this.line, this.kind, this.text, this.target);
  final String file;
  final int line;
  final String kind; // 'call' | 'ref'
  final String text;
  final String target; // 'Class.member' | 'member' (top-level) | '(unresolved)'
}

class _ResolvedFinder extends RecursiveAstVisitor<void> {
  _ResolvedFinder(this.symbol, this.lineInfo, this.file, this.lines, this.hits,
      this.refsMode, this.overrides);
  final String symbol;
  final LineInfo lineInfo;
  final String file;
  final List<String> lines;
  final List<_RHit> hits;
  final bool refsMode;
  // target key -> supertype methods it overrides ('State.build
  // [package:flutter/...]'). The refactor-safety signal: reshaping a method
  // that overrides a framework method breaks the override contract.
  final Map<String, List<String>> overrides;

  String _lineText(int line) =>
      (line >= 1 && line <= lines.length) ? lines[line - 1].trim() : '';

  // Element identity as a display key: `Enclosing.name` for a member,
  // bare `name` for a top-level, `(unresolved)` when the analyzer couldn't
  // bind it (dynamic receiver, missing dep) - the honest fallback.
  String _target(Element? el) {
    if (el == null) return '(unresolved)';
    final enc = el.enclosingElement?.name;
    final key =
        (enc != null && enc.isNotEmpty) ? '$enc.${el.name}' : (el.name ?? '?');
    overrides.putIfAbsent(key, () => _overridesOf(el));
    return key;
  }

  // Supertype methods [el] overrides, each with its declaring library so an
  // external (dart:/package:flutter) base is obvious. Empty for a standalone
  // method or a top-level function.
  List<String> _overridesOf(Element el) {
    final enc = el.enclosingElement;
    final name = el.name;
    if (enc is! InterfaceElement || name == null) return const [];
    final out = <String>[];
    for (final sup in enc.thisType.allSupertypes) {
      if (sup.getMethod(name) != null) {
        out.add('${sup.element.name}.$name '
            '[${portableLibraryUri(sup.element.library.uri)}]');
      }
    }
    return out;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == symbol) {
      final line = lineInfo.getLocation(node.methodName.offset).lineNumber;
      hits.add(_RHit(file, line, 'call', _lineText(line),
          _target(node.methodName.element)));
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (refsMode && node.name == symbol) {
      if (isRefactorReferenceUse(node) &&
          refactorSiteKind(node) != refactorSiteCall) {
        final line = lineInfo.getLocation(node.offset).lineNumber;
        hits.add(
            _RHit(file, line, 'ref', _lineText(line), _target(node.element)));
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final function = node.function;
    if (function is SimpleIdentifier && function.name == symbol) {
      final line = lineInfo.getLocation(function.offset).lineNumber;
      hits.add(_RHit(
          file, line, 'call', _lineText(line), _target(function.element)));
    }
    super.visitFunctionExpressionInvocation(node);
  }
}

/// Splits a `callers`/`refs` target spelled `Owner.member` into its parts;
/// `owner` is null for a bare name. `rename` and `find` both speak that
/// spelling, so it must resolve here as a name plus an owner filter: matched
/// whole, it is a literal no source file contains.
/// Target counts, most-called first, name-alphabetical within a tie.
List<MapEntry<String, int>> _byCountDesc(Map<String, int> counts) =>
    counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });

({String? owner, String name}) splitQualifiedTarget(String symbol) {
  final m = RegExp(r'^([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)$').firstMatch(
    symbol,
  );
  return m == null
      ? (owner: null, name: symbol)
      : (owner: m.group(1), name: m.group(2)!);
}

int _emitResolvedResults({
  required String verb,
  required String symbol,
  required bool refsMode,
  required int budget,
  required bool asJson,
  required bool caveat,
  required Graph graph,
  required List<_RHit> allHits,
  required Map<String, List<String>> overrides,
  required int unresolvedFiles,
  required bool indexed,
}) {
  // The owner is the owner part of [symbol] - derived, never passed, so the
  // two cannot disagree.
  final owner = splitQualifiedTarget(symbol).owner;
  // With an owner, sites bound to a DIFFERENT declaration of the same name are
  // not the answer - but they are not nothing either: a call through a
  // supertype-typed receiver dispatches to this override at runtime. An empty
  // list reads as dead code, so they are reported beside the answer.
  // Always a copy: this list is sorted in place below, and an alias of the
  // caller's would sort theirs too.
  final hits = [
    for (final h in allHits)
      if (owner == null || h.target == symbol) h,
  ];

  final overridden = {
    for (final e in overrides.entries)
      if (e.value.isNotEmpty) e.key: e.value,
  };

  // One pass over every site, read two ways: the answer's targets, and the
  // same-named declarations the owner filtered out.
  final byTarget = <String, int>{};
  for (final h in allHits) {
    byTarget[h.target] = (byTarget[h.target] ?? 0) + 1;
  }
  final elsewhereByTarget =
      owner == null ? const <String, int>{} : ({...byTarget}..remove(symbol));
  final elsewhereCount = elsewhereByTarget.values.fold<int>(0, (a, b) => a + b);
  final targets = _byCountDesc(owner == null
      ? byTarget
      : {if (byTarget.containsKey(symbol)) symbol: byTarget[symbol]!});

  int inDeg(String file) => graph.inDeg['file:$file'] ?? 0;
  hits.sort((a, b) {
    final byT = a.target.compareTo(b.target);
    if (byT != 0) return byT;
    final byDeg = inDeg(b.file).compareTo(inDeg(a.file));
    if (byDeg != 0) return byDeg;
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });

  if (asJson) {
    emitJson({
      ...envelope(verb, symbol),
      'resolved': true,
      if (indexed) 'indexed': true,
      'count': hits.length,
      'targets': {for (final e in targets) e.key: e.value},
      if (elsewhereByTarget.isNotEmpty) 'elsewhere': elsewhereByTarget,
      if (overridden.isNotEmpty) 'overrides': overridden,
      if (unresolvedFiles > 0) 'filesFellBack': unresolvedFiles,
      'hits': [
        for (final h in hits.take(budget))
          {
            'file': h.file,
            'line': h.line,
            'kind': h.kind,
            'target': h.target,
            'text': h.text,
          },
      ],
      if (hits.length > budget) 'truncated': hits.length - budget,
    });
    return 0;
  }

  final callN = hits.where((h) => h.kind == 'call').length;
  final refN = hits.length - callN;
  final header = refsMode
      ? 'references to $symbol — $callN calls + $refN other refs (element-resolved)'
      : 'callers of $symbol — $callN call sites (element-resolved)';
  final out = <String>[header];
  if (targets.length > 1) {
    out.add('  targets: ' +
        targets.map((e) => '${e.key} (${e.value})').take(8).join(', ') +
        (targets.length > 8 ? ', ...' : ''));
  }
  for (final e in overridden.entries) {
    out.add(
        '  (!) ${e.key} overrides ${e.value.join(', ')} - a rename/signature '
        'change must update the base + all overrides (external base = unsafe)');
  }
  if (hits.isEmpty) {
    out.add(elsewhereByTarget.isEmpty
        ? '  (none — element-resolved; try `find $symbol` or check the name)'
        : '  (none bound to $symbol itself - element-resolved)');
  }
  for (final h in hits) {
    final k = h.kind == 'ref' ? ' [ref]' : '';
    out.add('  ${h.file}:${h.line}$k -> ${h.target}  ${h.text}');
  }
  if (elsewhereByTarget.isNotEmpty) {
    final named = _byCountDesc(elsewhereByTarget);
    out.add('  ($elsewhereCount more site(s) of the same name bind to '
        '${named.map((e) => '${e.key} (${e.value})').take(6).join(', ')} - a '
        'call through a supertype-typed receiver is attributed to the '
        'declaration it binds to, and may dispatch here at runtime; drop the '
        '"$owner." qualifier to see them)');
  }
  if (unresolvedFiles > 0) {
    out.add('  (note: $unresolvedFiles files could not be resolved — '
        'their sites are omitted; drop --resolved for the name-match path)');
  }
  emit(out, budget, hint: 'raise --budget ${hits.length}');
  if (caveat) emitCaveats(verb);
  return 0;
}

int _runIndexedResolved({
  required String verb,
  required String symbol,
  required bool refsMode,
  required int budget,
  required bool asJson,
  required bool caveat,
  required Graph graph,
  required RefactorIndex index,
}) {
  final targetBySymbol = {
    for (final target in index.targets) target.symbol: target,
  };
  final want = splitQualifiedTarget(symbol);
  final sites = index.references.where((site) {
    final targetName = targetBySymbol[site.symbol]?.name;
    if ((targetName ?? executableName(site.symbol)) != want.name) return false;
    return refsMode || site.kind == refactorSiteCall;
  });
  final linesByFile = <String, List<String>>{};
  String lineText(String file, int line) {
    final lines = linesByFile.putIfAbsent(file, () {
      try {
        return File(file).readAsStringSync().split('\n');
      } on FileSystemException {
        return const [];
      }
    });
    return line >= 1 && line <= lines.length ? lines[line - 1].trim() : '';
  }

  final hits = <_RHit>[
    for (final site in sites)
      _RHit(
        site.file,
        site.line,
        site.kind,
        lineText(site.file, site.line),
        targetBySymbol[site.symbol]?.display ?? executableDisplay(site.symbol),
      ),
  ];
  final hitSymbols = {
    for (final site in sites) site.symbol,
  };
  final overrides = <String, List<String>>{};
  for (final target in hitSymbols) {
    final metadata = targetBySymbol[target];
    if (metadata == null) continue;
    overrides[metadata.display] = [
      for (final parent in metadata.overrides)
        '${targetBySymbol[parent]?.display ?? executableDisplay(parent)} '
            '[${targetBySymbol[parent]?.library ?? executableLibrary(parent)}]',
    ];
  }
  return _emitResolvedResults(
    verb: verb,
    symbol: symbol,
    refsMode: refsMode,
    budget: budget,
    asJson: asJson,
    caveat: caveat,
    graph: graph,
    allHits: hits,
    overrides: overrides,
    unresolvedFiles: 0,
    indexed: true,
  );
}

/// `callers|refs <Symbol> --resolved` - element-precise, attributed by target.
Future<int> runResolved(List<String> args, {bool caveat = true}) async {
  final verb = args.isNotEmpty ? args.first : 'callers';
  final refsMode = verb == 'refs';
  final positional = positionalArgs(args);
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: $verb <Symbol> --resolved');
    return 64;
  }
  final symbol = positional[1];
  final want = splitQualifiedTarget(symbol);

  if (!File('.dart_tool/package_config.json').existsSync()) {
    stderr.writeln('--resolved needs resolved dependencies but no '
        '.dart_tool/package_config.json was found. Run: dart pub get, then '
        'retry - or drop --resolved for the name-match path.');
    return 66;
  }

  final graph = loadFresh();
  if (graph == null) return 66;

  final index = RefactorIndex.load();
  if (!args.contains('--no-index') &&
      index != null &&
      index.complete &&
      (!refsMode || !index.nonExecutableNames.contains(want.name)) &&
      index.sourceDigest == graph.stats['sourceDigest']) {
    return _runIndexedResolved(
      verb: verb,
      symbol: symbol,
      refsMode: refsMode,
      budget: budget,
      asJson: asJson,
      caveat: caveat,
      graph: graph,
      index: index,
    );
  }

  final paths = <String>{
    for (final n in graph.nodes)
      if (n.isFile) n.id.replaceFirst('file:', ''),
  };
  final files = <File>[
    for (final p in paths)
      if (File(p).existsSync()) File(p),
    ...dartFilesUnderTestRoots(workspaceTestRoots(paths)),
  ];

  final AnalysisContextCollection collection;
  try {
    collection =
        newAnalysisCollection([for (final f in files) f.absolute.path]);
  } on ResolvedAnalysisUnavailable catch (unavailable) {
    stderr.writeln('$unavailable');
    stderr.writeln('Drop --resolved for the name-match path.');
    return 66;
  }
  final hits = <_RHit>[];
  final overrides = <String, List<String>>{};
  var unresolvedFiles = 0;
  final progress = ProgressReporter('resolve $verb', files.length)..start();
  var completed = 0;
  try {
    for (final f in files) {
      final String content;
      try {
        content = f.readAsStringSync();
      } on FileSystemException {
        progress.advance(++completed);
        continue;
      }
      if (!content.contains(want.name)) {
        progress.advance(++completed);
        continue; // prefilter: skip resolution
      }
      final abs = f.absolute.path;
      ResolvedUnitResult? r;
      try {
        final u = await collection
            .contextFor(abs)
            .currentSession
            .getResolvedUnit(abs);
        if (u is ResolvedUnitResult) r = u;
      } catch (_) {}
      if (r == null) {
        unresolvedFiles++;
        progress.advance(++completed);
        continue;
      }
      final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
      r.unit.accept(_ResolvedFinder(want.name, r.unit.lineInfo, rel,
          content.split('\n'), hits, refsMode, overrides));
      progress.advance(++completed);
    }
  } finally {
    await collection.dispose();
  }
  return _emitResolvedResults(
    verb: verb,
    symbol: symbol,
    refsMode: refsMode,
    budget: budget,
    asJson: asJson,
    caveat: caveat,
    graph: graph,
    allHits: hits,
    overrides: overrides,
    unresolvedFiles: unresolvedFiles,
    indexed: false,
  );
}
