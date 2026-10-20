import 'dart:io';
import 'dart:math';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'analysis.dart';
import 'kinds.dart';
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
      _entry(path).lines.getLocation(offset).lineNumber;

  /// Lines [first] to [last] of [path], numbered from 1, clipped to the file.
  List<String> lines(String path, int first, int last) {
    final e = _entry(path);
    final starts = e.lines.lineStarts;
    return [
      for (var n = max(first, 1); n <= min(last, starts.length); n++)
        e.text
            .substring(
              starts[n - 1],
              n < starts.length ? starts[n] : e.text.length,
            )
            .replaceFirst(_lineEnd, ''),
    ];
  }

  /// The trimmed text of [line] in [path]; empty when the file is gone.
  String lineText(String path, int line) {
    try {
      return lines(path, line, line).firstOrNull?.trim() ?? '';
    } on FileSystemException {
      return '';
    }
  }
}

final _lineEnd = RegExp(r'\r?\n$');

class _Entry {
  _Entry(this.text);
  final String text;
  late final LineInfo lines = LineInfo.fromContent(text);
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
  final Role role;

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
Role roleOf(Site site, SourceCache sources) {
  final node = nodeAt(sources.unit(site.path), site.offset);
  AstNode? child = node;
  var parent = node?.parent;
  for (var depth = 0; parent != null && depth < 12; depth++) {
    switch (parent) {
      case Comment():
        return Role.doc;
      case ImportDirective() || ExportDirective():
        return Role.import;
      case Annotation():
        return Role.annotation;
      case ExtendsClause():
        return Role.extend;
      case ImplementsClause():
        return Role.implement;
      case WithClause():
        return Role.mixin;
      case MixinOnClause():
        return Role.on;
      case MethodInvocation(
        :final methodName,
        :final argumentList,
        :final target,
      ):
        final role = providerRoles[methodName.name];
        if (role != null && argumentList == child) return role;
        if (methodName.name.startsWith('overrideWith') && target == child) {
          return Role.override;
        }
      case InstanceCreationExpression() when depth <= 3:
        return Role.construct;
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

Role _genericRole(String kind, AstNode? node) => switch (kind) {
  'INVOCATION' || 'INVOCATION_BY_ENUM_CONSTANT_WITHOUT_ARGUMENTS' => Role.call,
  'READ' => Role.read,
  'WRITE' || 'READ_WRITE' => Role.write,
  'REFERENCE_BY_NAMED_ARGUMENT' => Role.namedArg,
  'REFERENCE_BY_CONSTRUCTOR_TEAR_OFF' => Role.tearOff,
  'DOT_SHORTHANDS_CONSTRUCTOR_INVOCATION' => Role.construct,
  _ =>
    node?.parent is NamedType || node is NamedType ? Role.type : Role.reference,
};

/// Uses grouped for display: library code before tests, then by role.
List<((bool, Role), List<Use>)> groupByRole(Iterable<Use> uses) {
  final groups = <(bool, Role), List<Use>>{};
  for (final u in uses) {
    (groups[(u.inTest, u.role)] ??= []).add(u);
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      if (a.$1 != b.$1) return a.$1 ? 1 : -1;
      return a.$2.index.compareTo(b.$2.index);
    });
  return [for (final k in keys) (k, groups[k]!)];
}
