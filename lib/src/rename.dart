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

import 'freshness.dart';

const _testRoots = ['test', 'integration_test', 'patrol_test'];
final _ident = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$');

class _Edit {
  _Edit(this.file, this.offset, this.length, this.line);
  final String file;
  final int offset;
  final int length;
  final int line;
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

  final paths = <String>{
    for (final n in graph.nodes)
      if (n.isFile) n.id.replaceFirst('file:', ''),
  };
  final files = <File>[
    for (final p in paths)
      if (File(p).existsSync()) File(p),
    for (final root in _testRoots)
      if (Directory(root).existsSync())
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
  ];

  final collection = AnalysisContextCollection(
    includedPaths: [for (final f in files) f.absolute.path],
  );
  final allDecls = <Element, _Edit>{};
  final allRefs = <(Element, _Edit)>[];
  var unresolved = 0;
  for (final f in files) {
    final String content;
    try {
      content = f.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    if (!content.contains(wantName)) continue; // prefilter
    final abs = f.absolute.path;
    ResolvedUnitResult? r;
    try {
      final u =
          await collection.contextFor(abs).currentSession.getResolvedUnit(abs);
      if (u is ResolvedUnitResult) r = u;
    } catch (_) {}
    if (r == null) {
      unresolved++;
      continue;
    }
    final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
    final c = _Collector(wantName, rel, r.unit.lineInfo);
    r.unit.accept(c);
    allDecls.addAll(c.decls);
    allRefs.addAll(c.refs);
  }

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
  // Group by file, apply/print.
  final byFile = <String, List<_Edit>>{};
  for (final e in edits) {
    byFile.putIfAbsent(e.file, () => []).add(e);
  }

  if (asJson) {
    stdout.writeln(jsonEncode({
      'action': 'rename',
      'name': wantName,
      'newName': newName,
      'declarations': members,
      'sites': edits.length,
      'applied': apply,
      'edits': [
        for (final e in edits)
          {
            'file': e.file,
            'line': e.line,
            'offset': e.offset,
            'length': e.length
          }
      ],
    }));
  }

  var changed = 0;
  for (final entry in byFile.entries) {
    final file = File(entry.key);
    var text = file.readAsStringSync();
    // Descending offset so earlier edits don't shift later ones.
    final sorted = entry.value..sort((a, b) => b.offset.compareTo(a.offset));
    for (final e in sorted) {
      text = text.replaceRange(e.offset, e.offset + e.length, newName);
    }
    changed++;
    if (apply) file.writeAsStringSync(text);
  }

  if (!asJson) {
    final verb = apply ? 'renamed' : 'would rename';
    final set = members.length > 1
        ? ' across ${members.length} declarations '
            '(${members.take(6).join(', ')}${members.length > 6 ? ', ...' : ''})'
        : '';
    stdout.writeln('$verb $wantName -> $newName: ${edits.length} sites in '
        '$changed files$set'
        '${apply ? '' : ' (dry run; pass --apply to write)'}');
    for (final entry in byFile.entries) {
      for (final e in (entry.value..sort((a, b) => a.line.compareTo(b.line)))) {
        stdout.writeln('  ${e.file}:${e.line}');
      }
    }
  }
  return 0;
}
