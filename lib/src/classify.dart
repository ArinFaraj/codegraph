import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'analysis.dart';
import 'outline.dart';

/// File text and parse trees for the files a query touches, reused until the
/// file changes on disk.
class SourceCache {
  final Map<String, _Entry> _entries = {};

  _Entry _entry(String path) {
    final stat = FileStat.statSync(path);
    final stamp = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    final cached = _entries[path];
    if (cached != null && cached.stamp == stamp) return cached;
    final text = File(path).readAsStringSync();
    final entry = _Entry(stamp, text);
    if (_entries.length > 2000) _entries.clear();
    _entries[path] = entry;
    return entry;
  }

  String text(String path) => _entry(path).text;

  CompilationUnit unit(String path) => _entry(path).unit;

  int lineOf(String path, int offset) =>
      unit(path).lineInfo.getLocation(offset).lineNumber;

  String lineText(String path, int line) {
    final u = unit(path);
    final starts = u.lineInfo.lineStarts;
    if (line < 1 || line > starts.length) return '';
    final start = starts[line - 1];
    final end = line < starts.length ? starts[line] : text(path).length;
    return text(path).substring(start, end).trim();
  }
}

class _Entry {
  _Entry(this.stamp, this.text);
  final String stamp;
  final String text;
  CompilationUnit? _unit;
  CompilationUnit get unit =>
      _unit ??= parseString(content: text, throwIfDiagnostics: false).unit;
}

/// The innermost node covering [offset].
AstNode? nodeAt(CompilationUnit unit, int offset) {
  final finder = _Finder(offset);
  unit.accept(finder);
  return finder.found;
}

class _Finder extends GeneralizingAstVisitor<void> {
  _Finder(this.offset);
  final int offset;
  AstNode? found;

  @override
  void visitNode(AstNode node) {
    if (node.offset <= offset && offset < node.end) {
      found = node;
      node.visitChildren(this);
    }
  }
}

/// How a use reads in context. Riverpod roles win over the analyzer's
/// generic kinds because they are what a reader of provider code asks for.
String roleOf(Site site, SourceCache sources) {
  final AstNode? node;
  try {
    node = nodeAt(sources.unit(site.path), site.offset);
  } catch (_) {
    return _genericRole(site.kind, null);
  }
  AstNode? child = node;
  var parent = node?.parent;
  var depth = 0;
  while (parent != null && depth < 12) {
    if (parent is Comment) return 'doc';
    if (parent is ImportDirective || parent is ExportDirective) return 'import';
    if (parent is Annotation) return 'annotation';
    if (parent is ExtendsClause) return 'extend';
    if (parent is ImplementsClause) return 'implement';
    if (parent is WithClause) return 'mixin';
    if (parent is MixinOnClause) return 'on';
    if (parent is MethodInvocation) {
      final name = parent.methodName.name;
      if (child != null && parent.argumentList == child) {
        final role = providerRoles[name];
        if (role != null) return role;
      }
      if (name.startsWith('overrideWith') && parent.target == child) {
        return 'override';
      }
    }
    if (parent is InstanceCreationExpression && depth <= 3) return 'construct';
    if (parent is Statement || parent is Declaration) break;
    child = parent;
    parent = parent.parent;
    depth++;
  }
  return _genericRole(site.kind, node);
}

String _genericRole(String kind, AstNode? node) => switch (kind) {
  'INVOCATION' || 'INVOCATION_BY_ENUM_CONSTANT_WITHOUT_ARGUMENTS' => 'call',
  'READ' => 'read',
  'WRITE' || 'READ_WRITE' => 'write',
  'REFERENCE_BY_NAMED_ARGUMENT' => 'named arg',
  'REFERENCE_BY_CONSTRUCTOR_TEAR_OFF' => 'tear-off',
  'DOT_SHORTHANDS_CONSTRUCTOR_INVOCATION' => 'construct',
  _ => node?.parent is NamedType || node is NamedType ? 'type' : 'reference',
};

/// Display order of role sections.
const roleOrder = [
  'ref.watch',
  'ref.read',
  'ref.listen',
  'ref.invalidate',
  'ref.refresh',
  'ref.exists',
  'override',
  'call',
  'construct',
  'tear-off',
  'read',
  'write',
  'named arg',
  'type',
  'extend',
  'implement',
  'mixin',
  'on',
  'annotation',
  'reference',
  'import',
  'doc',
];

int roleRank(String role) {
  final i = roleOrder.indexOf(role);
  return i < 0 ? roleOrder.length : i;
}
