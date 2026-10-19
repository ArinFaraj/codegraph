import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'analysis.dart';
import 'outline.dart';

/// A resolved element plus where it is declared.
class Target {
  Target(this.element, this.path, this.line, this.offset);

  final Element element;

  /// Workspace-relative path of the declaring file.
  final String path;
  final int line;
  final int offset;

  String get name => element.displayName;

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

  String get kind => kindOf(element);
  String get location => '$path:$line';
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

/// A top-level variable whose static type is a Riverpod provider.
bool isProvider(Element e) {
  if (e is! TopLevelVariableElement) return false;
  final type = e.type;
  if (type is! InterfaceType) return false;
  for (final t in [type, ...type.element.allSupertypes]) {
    final name = t.element.name ?? '';
    final uri = t.element.library.uri.toString();
    if (uri.contains('riverpod') &&
        (name.endsWith('Provider') ||
            name.endsWith('ProviderBase') ||
            name.endsWith('ProviderListenable') ||
            name.endsWith('ProviderFamily'))) {
      return true;
    }
  }
  return false;
}

Target? targetOf(Analysis a, Element element) {
  final e = element.nonSynthetic;
  final fragment = e.firstFragment;
  final lib = fragment.libraryFragment;
  if (lib == null) return null;
  final offset = fragment.nameOffset ?? fragment.offset;
  final line = lib.lineInfo.getLocation(offset).lineNumber;
  return Target(e, a.workspace.relative(lib.source.fullName), line, offset);
}

sealed class Lookup {}

class Found extends Lookup {
  Found(this.targets);
  final List<Target> targets;
}

class NotFound extends Lookup {
  NotFound(this.message);
  final String message;
}

/// Resolves what a user typed to elements. Accepts `Name`, `Owner.member`,
/// `path.dart:name`, `path.dart:Owner.member` and `path.dart:line`.
Future<Lookup> lookup(Analysis a, OutlineIndex outlines, String query) async {
  final fileQuery = RegExp(r'^(.+\.dart):(.+)$').firstMatch(query);
  if (fileQuery != null) {
    final file = resolveFile(outlines, fileQuery.group(1)!);
    if (file == null)
      return NotFound('no analyzed file matches "${fileQuery.group(1)}"');
    final rest = fileQuery.group(2)!;
    final outline = outlines.files[file]!;
    final lineNo = int.tryParse(rest);
    var decls = lineNo != null
        ? outline.decls.where((d) => d.line == lineNo).toList()
        : outline.decls
              .where((d) => d.qualified == rest || (d.name == rest))
              .toList();
    if (lineNo != null && decls.length > 1) {
      final top = decls.where((d) => !d.isMember).toList();
      if (top.length == 1) decls = top;
    }
    if (decls.isEmpty) {
      return NotFound(
        lineNo != null
            ? 'nothing is declared on $file:$lineNo'
            : 'no declaration named "$rest" in $file',
      );
    }
    final lib = await a.library(file);
    if (lib == null) return NotFound('$file could not be resolved');
    final out = <Target>[];
    for (final d in decls) {
      for (final e in _elementsFor(lib.element, d.owner, d.name, file, a)) {
        final t = targetOf(a, e);
        if (t != null && !out.any((x) => x.element == t.element)) out.add(t);
      }
    }
    if (out.isEmpty) return NotFound('could not resolve "$rest" in $file');
    return Found(out);
  }

  final dot = query.lastIndexOf('.');
  if (dot > 0 && dot < query.length - 1) {
    final owner = query.substring(0, dot);
    final member = query.substring(dot + 1);
    final out = <Target>[];
    for (final e in await a.classMembers(member)) {
      if (e.enclosingElement?.name == owner) {
        final t = targetOf(a, e);
        if (t != null) out.add(t);
      }
    }
    for (final e in await a.topLevelElements(
      RegExp('^${RegExp.escape(owner)}\$'),
    )) {
      if (e is InterfaceElement) {
        final c = e.getNamedConstructor(member);
        if (c != null) {
          final t = targetOf(a, c);
          if (t != null) out.add(t);
        }
        for (final f in e.fields) {
          if (f.isEnumConstant && f.name == member) {
            final t = targetOf(a, f);
            if (t != null && !out.any((x) => x.element == t.element))
              out.add(t);
          }
        }
      }
    }
    if (out.isNotEmpty) return Found(_dedupe(out));
    return NotFound('no member "$member" declared on "$owner"');
  }

  final top = <Target>[];
  for (final e in await a.topLevelElements(
    RegExp('^${RegExp.escape(query)}\$'),
  )) {
    final t = targetOf(a, e);
    if (t != null) top.add(t);
  }
  if (top.isNotEmpty) return Found(_dedupe(top));
  final members = <Target>[];
  for (final e in await a.classMembers(query)) {
    final t = targetOf(a, e);
    if (t != null) members.add(t);
  }
  if (members.isNotEmpty) return Found(_dedupe(members));
  return NotFound('no declaration named "$query"');
}

List<Target> _dedupe(List<Target> targets) {
  final seen = <String>{};
  return [
    for (final t in targets)
      if (seen.add('${t.path}:${t.offset}')) t,
  ]..sort((a, b) => a.location.compareTo(b.location));
}

Iterable<Element> _elementsFor(
  LibraryElement lib,
  String? owner,
  String name,
  String file,
  Analysis a,
) sync* {
  bool inFile(Element e) {
    final f = e.nonSynthetic.firstFragment.libraryFragment;
    return f != null && a.workspace.relative(f.source.fullName) == file;
  }

  if (owner == null) {
    for (final e in lib.children) {
      if (e.name == name && inFile(e)) yield e;
    }
    for (final e in lib.topLevelVariables) {
      if (e.name == name && inFile(e)) yield e;
    }
    return;
  }
  for (final o in lib.children) {
    if (o.name != owner || !inFile(o)) continue;
    if (o is InterfaceElement) {
      if (owner == name) {
        final c = o.unnamedConstructor;
        if (c != null) yield c;
      }
      final named = o.getNamedConstructor(name);
      if (named != null) yield named;
    }
    for (final m in o.children) {
      if (m.name == name && m is! ConstructorElement) yield m.nonSynthetic;
    }
  }
}

/// Resolves a file argument: exact path, then unique basename, then unique
/// substring. When several match, a single one under `lib/` wins.
String? resolveFile(OutlineIndex outlines, String arg) {
  final candidates = fileCandidates(outlines, arg);
  return candidates.length == 1 ? candidates.single : null;
}

List<String> fileCandidates(OutlineIndex outlines, String arg) {
  final rel = outlines.workspace.relative(outlines.workspace.absolute(arg));
  if (outlines.files.containsKey(rel)) return [rel];
  if (outlines.files.containsKey(arg)) return [arg];
  final base =
      outlines.files.keys.where((p) => p == arg || p.endsWith('/$arg')).toList()
        ..sort();
  final pool = base.isNotEmpty
      ? base
      : (outlines.files.keys.where((p) => p.contains(arg)).toList()..sort());
  if (pool.length <= 1) return pool;
  final inLib = pool.where((p) => p.startsWith('lib/')).toList();
  return inLib.length == 1 ? inLib : pool;
}
