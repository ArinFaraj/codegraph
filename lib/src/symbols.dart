import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'declarations.dart';
import 'riverpod.dart';
import 'workspace.dart';

/// A resolved element plus where it is declared.
class Target {
  Target(this.element, this.at);

  final Element element;
  final Location at;

  String get path => at.path;
  int get line => at.line;
  int get offset => at.offset;
  String get name => element.displayName;
  String get kind => kindOf(element);
  String get location => '$path:$line';

  String get qualified {
    final owner = element.enclosingElement;
    if (owner is InterfaceElement || owner is ExtensionElement) {
      final o = owner!.displayName;
      if (element is ConstructorElement) {
        return element.displayName.isEmpty ? o : '$o.${element.displayName}';
      }
      return '$o.${element.displayName}';
    }
    return element.displayName;
  }

  Map<String, Object?> toJson() => {
    'name': qualified,
    'kind': kind,
    'path': path,
    'line': line,
  };
}

Target? targetOf(Analysis a, Element element) {
  final at = a.locate(element);
  return at == null ? null : Target(element.nonSynthetic, at);
}

String kindOf(Element e) {
  if (isProvider(e)) return 'provider';
  return switch (e) {
    ClassElement(isMixinClass: true) => 'mixin class',
    ClassElement() => 'class',
    EnumElement() => 'enum',
    MixinElement() => 'mixin',
    ExtensionTypeElement() => 'extension type',
    ExtensionElement() => 'extension',
    TypeAliasElement() => 'typedef',
    TopLevelFunctionElement() => 'function',
    TopLevelVariableElement() => 'variable',
    ConstructorElement() => 'constructor',
    MethodElement() => 'method',
    GetterElement() => 'getter',
    SetterElement() => 'setter',
    FieldElement(isEnumConstant: true) => 'enum value',
    FieldElement() => 'field',
    FormalParameterElement() => 'parameter',
    LocalVariableElement() => 'local variable',
    LocalFunctionElement() => 'local function',
    TypeParameterElement() => 'type parameter',
    _ => e.kind.displayName,
  };
}

/// A non-static field, getter, setter or method of a class, mixin, enum or
/// extension type: something an override or a dynamic call can reach.
bool isInstanceMember(Element e) {
  if (e.enclosingElement is! InterfaceElement) return false;
  return switch (e) {
    ConstructorElement() => false,
    ExecutableElement(isStatic: true) => false,
    FieldElement(isStatic: true) => false,
    ExecutableElement() || FieldElement() => true,
    _ => false,
  };
}

/// The declaration a use sits in, at the level a reader thinks of as "the
/// thing that uses it": a top-level declaration or a member.
Element declarationOwning(Element e) {
  var x = e;
  while (true) {
    final parent = x.enclosingElement;
    if (parent == null ||
        parent is LibraryElement ||
        parent is InstanceElement) {
      return x;
    }
    x = parent;
  }
}

sealed class Resolution {}

class Resolved extends Resolution {
  Resolved(this.target);
  final Target target;
}

class Ambiguous extends Resolution {
  Ambiguous(this.targets);
  final List<Target> targets;
}

class Missing extends Resolution {
  Missing(this.message);
  final String message;
}

Resolution _of(List<Target> found, String missing) {
  final seen = <String>{};
  final unique = [
    for (final t in found)
      if (seen.add('${t.path}:${t.offset}')) t,
  ]..sort((a, b) => a.location.compareTo(b.location));
  return switch (unique.length) {
    0 => Missing(missing),
    1 => Resolved(unique.single),
    _ => Ambiguous(unique),
  };
}

/// Resolves what a user typed to one element. Accepts `Name`,
/// `Owner.member`, `path.dart:name`, `path.dart:Owner.member` and
/// `path.dart:LINE` (the outermost declaration named on that line).
Future<Resolution> resolveSymbol(Analysis a, String query) async {
  final fileQuery = RegExp(r'^(.+\.dart):(.+)$').firstMatch(query);
  if (fileQuery != null) {
    final arg = fileQuery.group(1)!;
    final files = fileCandidates(a.workspace, a.files, arg);
    if (files.length != 1)
      return Missing('no single analyzed file matches "$arg"');
    final file = files.single;
    final unit = await a.unit(file);
    if (unit == null) return Missing('$file could not be resolved');
    final rest = fileQuery.group(2)!;
    final lineNo = int.tryParse(rest);
    final decls = declarationsOf(unit.unit);
    int line(DeclNode d) => unit.lineInfo.getLocation(d.nameOffset).lineNumber;
    final matches = lineNo != null
        ? decls.where((d) => line(d) == lineNo).toList()
        : decls.where((d) => d.qualified == rest || d.name == rest).toList();
    final chosen = lineNo != null && matches.isNotEmpty
        ? [matches.reduce((x, y) => x.isMember && !y.isMember ? y : x)]
        : matches;
    return _of(
      [
        for (final d in chosen)
          if (d.element case final e?)
            if (targetOf(a, e) case final t?) t,
      ],
      lineNo != null
          ? 'nothing is declared on $file:$lineNo'
          : 'no declaration named "$rest" in $file',
    );
  }

  final dot = query.lastIndexOf('.');
  if (dot > 0 && dot < query.length - 1) {
    final owner = query.substring(0, dot);
    final member = query.substring(dot + 1);
    final found = <Target>[
      for (final e in await a.classMembers(member))
        if (e.enclosingElement?.name == owner)
          if (targetOf(a, e) case final t?) t,
    ];
    for (final e in await a.topLevelElements(_exactly(owner))) {
      if (e is! InterfaceElement) continue;
      final ctor = e.getNamedConstructor(member);
      if (ctor != null) found.addAll([?targetOf(a, ctor)]);
      for (final f in e.fields) {
        if (f.isEnumConstant && f.name == member)
          found.addAll([?targetOf(a, f)]);
      }
    }
    return _of(found, 'no member "$member" declared on "$owner"');
  }

  final top = [
    for (final e in await a.topLevelElements(_exactly(query)))
      if (targetOf(a, e) case final t?) t,
  ];
  if (top.isNotEmpty) return _of(top, '');
  return _of([
    for (final e in await a.classMembers(query))
      if (targetOf(a, e) case final t?) t,
  ], 'no declaration named "$query"');
}

RegExp _exactly(String name) => RegExp('^${RegExp.escape(name)}\$');

/// The resolved declaration of [target], for its signature and members.
Future<(DeclNode, List<DeclNode>)?> declarationOf(
  Analysis a,
  Target target,
) async {
  final unit = await a.unit(target.path);
  if (unit == null) return null;
  final decls = declarationsOf(unit.unit);
  for (final d in decls) {
    if (d.nameOffset == target.offset) {
      return (
        d,
        [
          for (final m in decls)
            if (m.ownerNode == d.node) m,
        ],
      );
    }
  }
  return null;
}

/// Files matching a file argument: exact path, then unique basename, then
/// unique substring. When several match, a single one under `lib/` wins.
List<String> fileCandidates(Workspace ws, Iterable<String> files, String arg) {
  final all = files.toSet();
  final rel = ws.relative(ws.absolute(arg));
  if (all.contains(rel)) return [rel];
  final base = all.where((p) => p == arg || p.endsWith('/$arg')).toList()
    ..sort();
  final pool = base.isNotEmpty
      ? base
      : (all.where((p) => p.contains(arg)).toList()..sort());
  if (pool.length <= 1) return pool;
  final inLib = pool.where((p) => p.startsWith('lib/')).toList();
  return inLib.length == 1 ? inLib : pool;
}
