// `codegraph rename <Symbol> <newName>` - the first WRITE actuator (3.1).
//
// Element-precise rename: rewrites the declaration and EVERY element-resolved
// reference (not name matches), gated so it refuses anything it cannot do
// completely and safely. A wrong rename breaks the build - far worse than a
// missing one - so every gate is a refusal with a reason, never a guess. See
// plans/3.1-actuator-rename.md for the safety doctrine. Dry-run by default;
// `--apply` writes. Slow (query-time whole-context resolution) - the "once in a
// while" refactor case.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import 'analysis_env.dart';
import 'atomic_text_edits.dart';
import 'cancellation.dart';
import 'freshness.dart';
import 'progress.dart';
import 'refactor_index.dart';
import 'workspace_files.dart';

final _ident = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$');

class _Edit {
  _Edit(this.file, this.offset, this.length, this.line);
  final String file;
  final int offset;
  final int length;
  final int line;
}

typedef _Refuse = int Function(String reason, {Object? extra});

int _emitRename({
  required String wantName,
  required String newName,
  required List<_Edit> edits,
  required List<String> members,
  required bool asJson,
  required bool apply,
  required CancelGuard guard,
}) {
  final byFile = <String, List<_Edit>>{};
  var retainedBackups = <String>[];
  for (final e in edits) {
    byFile.putIfAbsent(e.file, () => []).add(e);
  }

  try {
    // Last safe point: nothing staged yet. From here staging + install run as
    // ONE uninterruptible unit (a cancel during it is disclosed afterwards).
    guard.checkpoint('apply');
    final prepared = prepareTextEdits([
      for (final edit in edits)
        AtomicTextEdit(
          file: edit.file,
          offset: edit.offset,
          length: edit.length,
          expected: wantName,
          replacement: newName,
        ),
    ]);
    if (apply) {
      retainedBackups = guard.critical(() => applyPreparedTextEdits(prepared));
    }
  } on AtomicEditException catch (error) {
    final code = error.ioFailure ? 74 : 3;
    if (asJson) {
      stdout.writeln(jsonEncode({
        'action': 'rename',
        'name': wantName,
        'newName': newName,
        'applied': false,
        'refused': error.message,
        if (error.details.isNotEmpty) 'detail': error.details,
        if (error.recoveryPaths.isNotEmpty)
          'recoveryPaths': error.recoveryPaths,
      }));
    } else {
      stderr.writeln('${code == 3 ? 'REFUSED' : 'ERROR'}: ${error.message}');
      for (final detail in error.details) {
        stderr.writeln('  - $detail');
      }
      for (final path in error.recoveryPaths) {
        stderr.writeln('  - recovery backup: $path');
      }
    }
    return code;
  } on FileSystemException catch (error) {
    if (asJson) {
      stdout.writeln(jsonEncode({
        'action': 'rename',
        'name': wantName,
        'newName': newName,
        'applied': false,
        'error': '$error',
      }));
    } else {
      stderr.writeln('ERROR: $error');
    }
    return 74;
  }

  final lateCancel = apply && guard.cancelRequested;
  if (lateCancel) {
    stderr.writeln('note: cancel arrived during the install - the rename WAS '
        'applied (the install/rollback section cannot be interrupted safely)');
  }
  if (asJson) {
    stdout.writeln(jsonEncode({
      'action': 'rename',
      'name': wantName,
      'newName': newName,
      'declarations': members,
      'sites': edits.length,
      'applied': apply,
      if (lateCancel) 'lateCancel': true,
      if (retainedBackups.isNotEmpty) 'retainedBackups': retainedBackups,
      'edits': [
        for (final e in edits)
          {
            'file': e.file,
            'line': e.line,
            'offset': e.offset,
            'length': e.length,
          },
      ],
    }));
  }

  if (!asJson) {
    final verb = apply ? 'renamed' : 'would rename';
    final set = members.length > 1
        ? ' across ${members.length} declarations '
            '(${members.take(6).join(', ')}${members.length > 6 ? ', ...' : ''})'
        : '';
    stdout.writeln('$verb $wantName -> $newName: ${edits.length} sites in '
        '${byFile.length} files$set'
        '${apply ? '' : ' (dry run; pass --apply to write)'}');
    for (final entry in byFile.entries) {
      for (final e in (entry.value..sort((a, b) => a.line.compareTo(b.line)))) {
        stdout.writeln('  ${e.file}:${e.line}');
      }
    }
    for (final path in retainedBackups) {
      stderr.writeln('warning: applied successfully; remove retained backup: '
          '$path');
    }
  }
  return 0;
}

int _runIndexed({
  required RefactorIndex index,
  required String targetArg,
  required String? wantClass,
  required String wantName,
  required String newName,
  required bool asJson,
  required bool apply,
  required _Refuse refuse,
  required CancelGuard guard,
}) {
  if (index.unresolvedNames.contains(wantName)) {
    return refuse(
      'unresolved or dynamic uses of "$wantName" exist - cannot guarantee a '
      'complete rename',
    );
  }
  final named = index.declarations.where((d) => d.name == wantName).toList();
  var candidates = named;
  if (wantClass != null) {
    candidates = named.where((d) => d.owner == wantClass).toList();
  }
  if (candidates.isEmpty) {
    return refuse('no declaration of "$targetArg" found in the resolved graph');
  }

  final namedSymbols = {for (final d in named) d.symbol};
  final adjacent = <String, Set<String>>{
    for (final symbol in namedSymbols) symbol: <String>{},
  };
  for (final d in named) {
    for (final parent in d.overrides) {
      if (namedSymbols.contains(parent)) {
        adjacent[d.symbol]!.add(parent);
        adjacent[parent]!.add(d.symbol);
      }
    }
  }
  final component = <String>{candidates.first.symbol};
  final queue = <String>[candidates.first.symbol];
  while (queue.isNotEmpty) {
    for (final next in adjacent[queue.removeLast()]!) {
      if (component.add(next)) queue.add(next);
    }
  }

  final selectedCandidates = candidates.map((d) => d.symbol).toSet();
  if (wantClass == null && component.length != namedSymbols.length) {
    return refuse(
      'ambiguous: "$wantName" names methods in unrelated hierarchies - qualify '
      'as Class.method',
      extra: [for (final d in named) d.display],
    );
  }
  if (wantClass != null && !component.containsAll(selectedCandidates)) {
    return refuse(
      'ambiguous: "$targetArg" exists in unrelated libraries',
      extra: [for (final d in candidates) d.display],
    );
  }

  for (final declaration in named.where((d) => component.contains(d.symbol))) {
    final collisions = index.declarations.where((candidate) =>
        candidate.name == newName &&
        candidate.library == declaration.library &&
        candidate.owner == declaration.owner);
    if (collisions.isNotEmpty) {
      return refuse(
        '"$newName" is already declared in the target scope',
        extra: [for (final collision in collisions) collision.display],
      );
    }
  }

  for (final d in named.where((d) => component.contains(d.symbol))) {
    for (final parent in d.overrides) {
      if (!index.declarations.any((candidate) => candidate.symbol == parent)) {
        return refuse(
          '"$targetArg" (or an override in its set) overrides a method outside '
          'the project - renaming would break that contract',
          extra: [parent],
        );
      }
    }
  }

  final edits = <_Edit>[
    for (final d in named)
      if (component.contains(d.symbol))
        _Edit(d.file, d.offset, d.length, d.line),
    for (final r in index.references)
      if (component.contains(r.symbol))
        _Edit(r.file, r.offset, r.length, r.line),
  ];
  final members = [
    for (final d in named)
      if (component.contains(d.symbol)) '${d.owner ?? '(top-level)'}.${d.name}',
  ]..sort();
  return _emitRename(
    wantName: wantName,
    newName: newName,
    edits: edits,
    members: members,
    asJson: asJson,
    apply: apply,
    guard: guard,
  );
}

/// Collects, per resolved unit: declarations named [name] (element + name-token
/// span) and every reference named [name] that binds to an element (call sites,
/// tear-offs, refs). Element identity - set by the caller after the target is
/// chosen - decides which references belong to the rename.
class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.name, this.file, this.lineInfo);
  final String name;
  final String file;
  final LineInfo lineInfo;
  // declared element -> its name-token edit (offset/length at the decl site).
  final Map<Element, _Edit> decls = {};
  // (element, edit) for every reference that binds somewhere.
  final List<(Element, _Edit)> refs = [];

  int _line(int offset) => lineInfo.getLocation(offset).lineNumber;

  void _decl(Element? el, int offset, int length) {
    if (el != null) decls[el] = _Edit(file, offset, length, _line(offset));
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == name) {
      _decl(node.declaredFragment?.element, node.name.offset, node.name.length);
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.name.lexeme == name) {
      _decl(node.declaredFragment?.element, node.name.offset, node.name.length);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == name) {
      // Declaration NAMES are Tokens, not identifiers, so anything reaching
      // here is a use. Record with its bound element for identity matching.
      final el = node.element;
      if (el != null) {
        refs.add(
            (el, _Edit(file, node.offset, node.length, _line(node.offset))));
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

/// The supertype method ELEMENTS [el] overrides. Whether each is in the scanned
/// declaration set decides in-project base (renamable) vs external/framework
/// base (refuse). Empty for a standalone method or a top-level function.
List<Element> _overriddenSupers(Element el) {
  final enc = el.enclosingElement;
  final name = el.name;
  if (enc is! InterfaceElement || name == null) return const [];
  return [
    for (final s in enc.thisType.allSupertypes)
      if (s.getMethod(name) case final m?) m,
  ];
}

/// `Class.name [library-uri]` for a method element (refusal messages).
String _describe(Element el) =>
    '${el.enclosingElement?.name ?? '(top-level)'}.${el.name} '
    '[${el.library?.uri}]';

bool _sameDeclarationScope(Element a, Element b) {
  final aOwner = a.enclosingElement;
  final bOwner = b.enclosingElement;
  if (aOwner is LibraryElement && bOwner is LibraryElement) {
    return a.library == b.library;
  }
  return aOwner == bOwner;
}

/// True if classes [a] and [b] are in an inheritance relationship (one is a
/// supertype of the other) - same-named methods on them form an override set.
bool _related(InterfaceElement a, InterfaceElement b) {
  if (a == b) return true;
  bool has(InterfaceElement x, InterfaceElement y) =>
      x.thisType.allSupertypes.any((s) => s.element == y);
  return has(a, b) || has(b, a);
}

/// The override component containing [start]: the transitive closure over
/// inheritance-related classes (among [decls] that declare the method) - base +
/// every override + every sibling override, the full set that must rename
/// together. A top-level function (no enclosing class) is its own component.
Set<Element> _overrideComponent(Element start, Iterable<Element> decls) {
  final seen = <Element>{start};
  final queue = <Element>[start];
  while (queue.isNotEmpty) {
    final cur = queue.removeLast();
    final curEnc = cur.enclosingElement;
    if (curEnc is! InterfaceElement) continue;
    for (final o in decls) {
      final oEnc = o.enclosingElement;
      if (!seen.contains(o) &&
          oEnc is InterfaceElement &&
          _related(curEnc, oEnc)) {
        seen.add(o);
        queue.add(o);
      }
    }
  }
  return seen;
}

Future<int> run(List<String> args) async {
  try {
    return await CancelGuard.run((guard) => _run(args, guard));
  } on OperationCancelled catch (cancelled) {
    // Only reachable from checkpoints OUTSIDE the critical section, where
    // nothing is staged - so this claim about disk state is exact.
    if (args.contains('--json')) {
      stdout.writeln(jsonEncode({
        'action': 'rename',
        'cancelled': cancelled.phase,
        'applied': false,
      }));
    } else {
      stderr.writeln(
          'cancelled during ${cancelled.phase}; no changes were applied');
    }
    return 130;
  }
}

Future<int> _run(List<String> args, CancelGuard guard) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final asJson = args.contains('--json');
  final apply = args.contains('--apply');
  if (positional.length < 3) {
    stderr.writeln('usage: rename <Symbol|Class.method> <newName> [--apply]');
    return 64;
  }
  final targetArg = positional[1];
  final newName = positional[2];

  int refuse(String reason, {Object? extra}) {
    if (asJson) {
      stdout.writeln(jsonEncode({
        'action': 'rename',
        'target': targetArg,
        'newName': newName,
        'refused': reason,
        if (extra != null) 'detail': extra,
      }));
    } else {
      stderr.writeln('REFUSED: $reason');
      if (extra is List) {
        for (final e in extra) {
          stderr.writeln('  - $e');
        }
      }
    }
    return 3; // distinct "actuator refused" code
  }

  if (!_ident.hasMatch(newName)) {
    return refuse('"$newName" is not a valid Dart identifier');
  }
  if (!File('.dart_tool/package_config.json').existsSync()) {
    return refuse('rename needs resolved dependencies (no '
        '.dart_tool/package_config.json). Run: dart pub get');
  }

  final graph = loadFresh();
  if (graph == null) return 66;

  final dot = targetArg.lastIndexOf('.');
  final wantClass = dot > 0 ? targetArg.substring(0, dot) : null;
  final wantName = dot > 0 ? targetArg.substring(dot + 1) : targetArg;
  if (wantName == newName) return refuse('new name equals the old name');

  final index = RefactorIndex.load();
  if (!args.contains('--no-index') &&
      index != null &&
      index.complete &&
      index.sourceDigest == graph.stats['sourceDigest']) {
    return _runIndexed(
      index: index,
      targetArg: targetArg,
      wantClass: wantClass,
      wantName: wantName,
      newName: newName,
      asJson: asJson,
      apply: apply,
      refuse: refuse,
      guard: guard,
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
    return refuse('$unavailable');
  }
  final allDecls = <Element, _Edit>{};
  final allRefs = <(Element, _Edit)>[];
  final newNameDecls = <Element>[];
  var unresolved = 0;
  final progress = ProgressReporter('resolve rename', files.length)..start();
  var completed = 0;
  for (final f in files) {
    // Safe point: nothing is staged during analysis, so a ctrl-C here aborts
    // with the tree untouched.
    guard.checkpoint('resolve');
    final String content;
    try {
      content = f.readAsStringSync();
    } on FileSystemException {
      progress.advance(++completed);
      continue;
    }
    if (!content.contains(wantName) && !content.contains(newName)) {
      progress.advance(++completed);
      continue; // prefilter
    }
    final abs = f.absolute.path;
    ResolvedUnitResult? r;
    try {
      final u =
          await collection.contextFor(abs).currentSession.getResolvedUnit(abs);
      if (u is ResolvedUnitResult) r = u;
    } catch (_) {}
    if (r == null) {
      unresolved++;
      progress.advance(++completed);
      continue;
    }
    final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
    if (content.contains(wantName)) {
      final c = _Collector(wantName, rel, r.unit.lineInfo);
      r.unit.accept(c);
      allDecls.addAll(c.decls);
      allRefs.addAll(c.refs);
    }
    if (content.contains(newName)) {
      final c = _Collector(newName, rel, r.unit.lineInfo);
      r.unit.accept(c);
      newNameDecls.addAll(c.decls.keys);
    }
    progress.advance(++completed);
  }
  await collection.dispose();

  // Gate: completeness. A file with the name that would not resolve could hide
  // a reference - refuse rather than do a partial (build-breaking) rename.
  if (unresolved > 0) {
    return refuse('$unresolved file(s) containing "$wantName" failed to '
        'resolve - cannot guarantee a complete rename');
  }

  var candidates = allDecls.keys.toList();
  if (wantClass != null) {
    candidates =
        candidates.where((e) => e.enclosingElement?.name == wantClass).toList();
  }
  if (candidates.isEmpty) {
    return refuse('no declaration of "$targetArg" found in the resolved graph');
  }

  // The override set: the target's declaration plus every inheritance-related
  // declaration (base, overrides, siblings) - all must rename together.
  final component = _overrideComponent(candidates.first, allDecls.keys);

  // A bare name whose declarations span MORE than the target's component names
  // unrelated methods (different hierarchies / a top-level fn plus a method) -
  // genuinely ambiguous. A qualified Class.method scopes to one component, so
  // other unrelated same-named methods are correctly ignored.
  if (wantClass == null && component.length != allDecls.length) {
    return refuse(
      'ambiguous: "$wantName" names methods in unrelated hierarchies - qualify '
      'as Class.method',
      extra: [for (final e in allDecls.keys) _describe(e)],
    );
  }

  for (final declaration in component) {
    final collisions = newNameDecls.where(
      (candidate) => _sameDeclarationScope(declaration, candidate),
    );
    if (collisions.isNotEmpty) {
      return refuse(
        '"$newName" is already declared in the target scope',
        extra: [for (final collision in collisions) _describe(collision)],
      );
    }
  }

  // Gate: no member of the set may override a method OUTSIDE the set. That base
  // is external/framework (or unscanned), so renaming would silently break the
  // override contract. This is the completeness proof: the set is closed under
  // override-up, so renaming every member + every reference is total.
  for (final m in component) {
    for (final s in _overriddenSupers(m)) {
      if (!allDecls.containsKey(s)) {
        return refuse(
          '"$targetArg" (or an override in its set) overrides a method outside '
          'the project - renaming would break that contract',
          extra: [_describe(s)],
        );
      }
    }
  }

  // Collect edits: every declaration in the set + every reference bound (by
  // element identity, not name) to any element in the set.
  final edits = <_Edit>[
    for (final m in component) allDecls[m]!,
    for (final (el, e) in allRefs)
      if (component.contains(el)) e,
  ];
  final members = [
    for (final m in component)
      '${m.enclosingElement?.name ?? '(top-level)'}.${m.name}'
  ]..sort();
  return _emitRename(
    wantName: wantName,
    newName: newName,
    edits: edits,
    members: members,
    asJson: asJson,
    apply: apply,
    guard: guard,
  );
}
