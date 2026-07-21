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

/// Package names from codegraph.json `publishedPackages`: local packages whose
/// PUBLIC API is consumed outside this repository, so its completeness can
/// never be proven from the graph. Mined from the first Stage A campaign,
/// where both agent arms renamed a published package's public class despite a
/// prose warning - the boundary must be graph data, not prose.
Set<String> _publishedPackages() {
  try {
    final decoded = jsonDecode(File('codegraph.json').readAsStringSync());
    final list = (decoded as Map<String, dynamic>)['publishedPackages'];
    if (list is List) return {for (final e in list) e.toString()};
  } catch (_) {}
  return const {};
}

/// The published package owning [file] (`packages/<name>/...`), or null.
String? _publishedPackageOf(String file, Set<String> published) {
  final m = RegExp(r'^packages/([^/]+)/').firstMatch(file);
  final name = m?.group(1);
  return (name != null && published.contains(name)) ? name : null;
}

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
  required String? wantFile,
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
    candidates = candidates.where((d) => d.owner == wantClass).toList();
  }
  if (wantFile != null) {
    candidates = candidates.where((d) => d.file == wantFile).toList();
  }
  if (candidates.isEmpty) {
    // Not in the EXECUTABLE index - the target may still be a class, enum, or
    // mixin (or genuinely absent). Sentinel -1 tells run() to fall through to
    // the cold analyzer path, which handles non-executable symbols and issues
    // the honest not-found refusal itself.
    return -1;
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
  if (wantClass == null &&
      wantFile == null &&
      component.length != namedSymbols.length) {
    return refuse(
      'ambiguous: "$wantName" names declarations in unrelated places - '
      'qualify as Class.member or path/to/file.dart:name',
      extra: [for (final d in named) d.display],
    );
  }
  if ((wantClass != null || wantFile != null) &&
      !component.containsAll(selectedCandidates)) {
    return refuse(
      'ambiguous: "$targetArg" matches multiple unrelated declarations - '
      'qualify as Class.member',
      extra: [for (final d in candidates) d.display],
    );
  }

  final published = _publishedPackages();
  for (final declaration in named.where((d) => component.contains(d.symbol))) {
    final pkg = _publishedPackageOf(declaration.file, published);
    if (pkg != null && !wantName.startsWith('_')) {
      return refuse(
        '"$targetArg" is public API of published package "$pkg" '
        '(codegraph.json publishedPackages) - external consumers cannot be '
        'seen from this repository, so a complete rename cannot be proven',
        extra: [declaration.display],
      );
    }
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
  void visitClassDeclaration(ClassDeclaration node) {
    final t = node.namePart.typeName;
    if (t.lexeme == name) {
      _decl(node.declaredFragment?.element, t.offset, t.length);
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final t = node.namePart.typeName;
    if (t.lexeme == name) {
      _decl(node.declaredFragment?.element, t.offset, t.length);
    }
    super.visitEnumDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    if (node.name.lexeme == name) {
      _decl(node.declaredFragment?.element, node.name.offset, node.name.length);
    }
    super.visitMixinDeclaration(node);
  }

  // Top-level variables (Riverpod providers are exactly this shape - mined
  // from campaign v2, where the provider half of a pair rename had no covering
  // declaration). Fields are deliberately NOT captured: initializing formals
  // (`this.x`) and named arguments need their own edit forms first.
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name) {
      final el = node.declaredFragment?.element;
      if (el is TopLevelVariableElement) {
        _decl(el, node.name.offset, node.name.length);
      }
    }
    super.visitVariableDeclaration(node);
  }

  // Every type mention flows through NamedType on a resolved unit: type
  // annotations, extends/implements/with clauses, is/as, type arguments, and
  // the ConstructorName inside Foo()/Foo.named()/Foo.new (probe-verified -
  // the same resolver rewrite that bit GoRoute). The name is a Token here, so
  // visitSimpleIdentifier never sees these; without this visitor a class
  // rename would silently miss every type reference.
  @override
  void visitNamedType(NamedType node) {
    if (node.name.lexeme == name) {
      final el = node.element;
      if (el != null) {
        refs.add((
          el,
          _Edit(file, node.name.offset, node.name.length,
              _line(node.name.offset)),
        ));
      }
    }
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == name) {
      // Declaration NAMES are Tokens, not identifiers, so anything reaching
      // here is a use. Record with its bound element for identity matching.
      final el = node.element;
      if (el != null) {
        final edit = _Edit(file, node.offset, node.length, _line(node.offset));
        refs.add((el, edit));
        // Reads of a variable bind to its implicit GETTER, not the variable -
        // record the canonical variable identity too so variable renames match.
        // (Write sites bind element: null on the identifier and resolve via
        // writeElement on the assignment - which is why only setter-less
        // variables are renameable; see the selection gate.)
        if (el is PropertyAccessorElement) {
          refs.add((el.variable, edit));
        }
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
    '[${el.library == null ? null : portableLibraryUri(el.library!.uri)}]';

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

  // Three target spellings: bare `name`, `Class.member`, and the file-scoped
  // `path/to/file.dart:name` (benchmark-mined: two files may declare the same
  // private top-level helper, which Class.member cannot disambiguate - the
  // Stage A private-helper task became un-completable through the actuator
  // until this existed).
  String? wantFile;
  String? wantClass;
  final String wantName;
  final colon = targetArg.lastIndexOf(':');
  if (colon > 0 && targetArg.substring(0, colon).endsWith('.dart')) {
    var f = targetArg.substring(0, colon);
    if (f.startsWith('./')) f = f.substring(2);
    wantFile = f;
    wantName = targetArg.substring(colon + 1);
  } else {
    final dot = targetArg.lastIndexOf('.');
    wantClass = dot > 0 ? targetArg.substring(0, dot) : null;
    wantName = dot > 0 ? targetArg.substring(dot + 1) : targetArg;
  }
  if (wantName == newName) return refuse('new name equals the old name');

  final index = RefactorIndex.load();
  if (!args.contains('--no-index') &&
      index != null &&
      index.complete &&
      index.sourceDigest == graph.stats['sourceDigest']) {
    final indexed = _runIndexed(
      index: index,
      targetArg: targetArg,
      wantClass: wantClass,
      wantFile: wantFile,
      wantName: wantName,
      newName: newName,
      asJson: asJson,
      apply: apply,
      refuse: refuse,
      guard: guard,
    );
    if (indexed != -1) return indexed;
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
  if (wantFile != null) {
    candidates =
        candidates.where((e) => allDecls[e]!.file == wantFile).toList();
  }
  if (candidates.isEmpty) {
    return refuse('no declaration of "$targetArg" found in the resolved graph');
  }

  // Gate: an ASSIGNABLE top-level variable has write sites that bind to its
  // setter via the assignment node, not the identifier - the collector cannot
  // prove it saw them all, so refuse rather than break every write. Final and
  // const variables (no setter) - the Riverpod provider shape - are complete.
  for (final e in candidates) {
    if (e is TopLevelVariableElement && e.setter != null) {
      return refuse(
        '"$targetArg" is an assignable (non-final) top-level variable - '
        'write sites cannot be proven complete yet; make it final or rename '
        'manually with codegraph refs',
      );
    }
  }

  // The override set: the target's declaration plus every inheritance-related
  // declaration (base, overrides, siblings) - all must rename together.
  final component = _overrideComponent(candidates.first, allDecls.keys);

  // Gate: published-package boundary (same rule as the indexed path).
  final published = _publishedPackages();
  if (!wantName.startsWith('_')) {
    for (final m in component) {
      final pkg = _publishedPackageOf(allDecls[m]!.file, published);
      if (pkg != null) {
        return refuse(
          '"$targetArg" is public API of published package "$pkg" '
          '(codegraph.json publishedPackages) - external consumers cannot be '
          'seen from this repository, so a complete rename cannot be proven',
          extra: ['${m.enclosingElement?.name ?? '(top-level)'}.${m.name}'],
        );
      }
    }
  }

  // A bare name whose declarations span MORE than the target's component names
  // unrelated methods (different hierarchies / a top-level fn plus a method) -
  // genuinely ambiguous. A qualified Class.method scopes to one component, so
  // other unrelated same-named methods are correctly ignored.
  if (wantFile != null && !candidates.every((e) => component.contains(e))) {
    return refuse(
      'ambiguous: "$targetArg" matches multiple unrelated declarations in '
      'that file - qualify as Class.member',
      extra: [for (final e in candidates) _describe(e)],
    );
  }
  if (wantClass == null &&
      wantFile == null &&
      component.length != allDecls.length) {
    return refuse(
      'ambiguous: "$wantName" names declarations in unrelated places - '
      'qualify as Class.member or path/to/file.dart:name',
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
