import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'analysis.dart';
import 'riverpod.dart';
import 'workspace.dart';

/// File text and parse trees by workspace-relative path. Entries live until
/// the engine invalidates them, which it does for every file the analyzer
/// reports as changed.
class SourceCache {
  SourceCache(this.workspace);

  final Workspace workspace;
  final Map<String, _Entry> _entries = {};

  void invalidate(Iterable<String> paths) => paths.forEach(_entries.remove);

  _Entry _entry(String path) => _entries[path] ??= _Entry(
    File(workspace.absolute(path)).readAsStringSync(),
  );

  String text(String path) => _entry(path).text;

  CompilationUnit unit(String path) => _entry(path).unit;

  int lineOf(String path, int offset) =>
      unit(path).lineInfo.getLocation(offset).lineNumber;

  String lineText(String path, int line) {
    final starts = unit(path).lineInfo.lineStarts;
    if (line < 1 || line > starts.length) return '';
    final text = this.text(path);
    final end = line < starts.length ? starts[line] : text.length;
    return text.substring(starts[line - 1], end).trim();
  }
}

class _Entry {
  _Entry(this.text);
  final String text;
  late final CompilationUnit unit = parseString(
    content: text,
    throwIfDiagnostics: false,
  ).unit;
}

/// A use of an element, located and classified once.
class Use {
  Use(this.site, this.line, this.role, this.source, {required this.inTest});

  final Site site;
  final int line;
  final String role;

  /// The trimmed source line the use sits on.
  final String source;
  final bool inTest;

  String get path => site.path;
  String get location => '$path:$line';
}

Use classify(Site site, SourceCache sources) {
  final line = sources.lineOf(site.path, site.offset);
  return Use(
    site,
    line,
    roleOf(site, sources),
    sources.lineText(site.path, line),
    inTest: isTestPath(site.path),
  );
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
  final node = nodeAt(sources.unit(site.path), site.offset);
  AstNode? child = node;
  var parent = node?.parent;
  for (var depth = 0; parent != null && depth < 12; depth++) {
    switch (parent) {
      case Comment():
        return 'doc';
      case ImportDirective() || ExportDirective():
        return 'import';
      case Annotation():
        return 'annotation';
      case ExtendsClause():
        return 'extend';
      case ImplementsClause():
        return 'implement';
      case WithClause():
        return 'mixin';
      case MixinOnClause():
        return 'on';
      case MethodInvocation(
        :final methodName,
        :final argumentList,
        :final target,
      ):
        final role = providerRoles[methodName.name];
        if (role != null && argumentList == child) return role;
        if (methodName.name.startsWith('overrideWith') && target == child) {
          return 'override';
        }
      case InstanceCreationExpression() when depth <= 3:
        return 'construct';
      case Statement() || Declaration():
        return _genericRole(site.kind, node);
      default:
        break;
    }
    child = parent;
    parent = parent.parent;
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

/// Uses grouped for display: library code before tests, then by role.
List<((bool, String), List<Use>)> groupByRole(Iterable<Use> uses) {
  final groups = <(bool, String), List<Use>>{};
  for (final u in uses) {
    (groups[(u.inTest, u.role)] ??= []).add(u);
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      if (a.$1 != b.$1) return a.$1 ? 1 : -1;
      return roleRank(a.$2).compareTo(roleRank(b.$2));
    });
  return [for (final k in keys) (k, groups[k]!)];
}
