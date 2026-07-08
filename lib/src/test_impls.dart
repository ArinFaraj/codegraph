// `impls <Type>` is built from the lib-only graph, so a fake/mock that
// implements or extends an interface ONLY in a test root (the common
// `_FakeRepo implements Repo` shape) is invisible — the exact blind spot that
// bites when you change an interface signature and the build breaks in tests
// the graph never listed. This on-demand scan of the same test roots
// `callers` scans finds those subtypes so `impls` can list them, labeled
// `(test)`. Syntax-only, name-matched — like the rest of the tool.
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

const _testRoots = ['test', 'integration_test', 'patrol_test'];

/// A subtype declared in a test root (outside the lib-only graph).
class TestSubtype {
  TestSubtype(this.child, this.parent, this.file, this.line, this.relation);
  final String child;
  final String parent; // the queried/known type name it references
  final String file;
  final int line;
  final String relation; // extends | implements | with | on
}

String _bare(String type) => type.split('<').first.trim();

/// Every class/mixin under the test roots whose extends/implements/with/on
/// clause names any type in [parents]. A cheap textual pre-filter skips files
/// that can't match before the parse.
List<TestSubtype> testSubtypesOf(Set<String> parents) {
  final out = <TestSubtype>[];
  if (parents.isEmpty) return out;
  for (final root in _testRoots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final String content;
      try {
        content = f.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      if (!parents.any(content.contains)) continue;
      final unit =
          parseString(content: content, throwIfDiagnostics: false).unit;
      final lineInfo = unit.lineInfo;
      final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
      void add(String child, int offset, String? typeSrc, String relation) {
        if (typeSrc == null) return;
        final parent = _bare(typeSrc);
        if (parents.contains(parent)) {
          out.add(TestSubtype(child, parent, rel,
              lineInfo.getLocation(offset).lineNumber, relation));
        }
      }

      for (final d in unit.declarations) {
        if (d is ClassDeclaration) {
          final child = _bare(d.namePart.toSource());
          final off = d.namePart.offset;
          add(child, off, d.extendsClause?.superclass.toSource(), 'extends');
          for (final i in d.implementsClause?.interfaces ?? const []) {
            add(child, off, i.toSource(), 'implements');
          }
          for (final m in d.withClause?.mixinTypes ?? const []) {
            add(child, off, m.toSource(), 'with');
          }
        } else if (d is MixinDeclaration) {
          final child = d.name.lexeme;
          final off = d.name.offset;
          for (final i in d.implementsClause?.interfaces ?? const []) {
            add(child, off, i.toSource(), 'implements');
          }
          for (final c in d.onClause?.superclassConstraints ?? const []) {
            add(child, off, c.toSource(), 'on');
          }
        }
      }
    }
  }
  out.sort((a, b) {
    final c = a.child.compareTo(b.child);
    return c != 0 ? c : a.file.compareTo(b.file);
  });
  return out;
}
