// Pure signature-rendering helpers shared by `engine.dart` (symbol records on
// file nodes) and, in a later stage, `skeleton.dart` (per-file outline).
//
// No I/O here — every function takes AST nodes (+ a `LineInfo` where a line
// number is needed) and returns strings/records. Keep it that way so both
// call sites can depend on it without pulling engine.dart's file-walking
// concerns along.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

/// One symbol (class/mixin/enum/fn/ext/typedef) on a file node.
class SymbolRec {
  SymbolRec(this.name, this.kind, this.line, this.sig,
      {this.doc, this.members, this.memberIndex});

  factory SymbolRec.fromJson(Map<String, dynamic> j) => SymbolRec(
        j['n'] as String,
        j['k'] as String,
        j['l'] as int,
        j['sig'] as String,
        doc: j['doc'] as String?,
        members: (j['members'] as List?)?.cast<String>(),
        memberIndex: (j['mi'] as List?)?.cast<String>(),
      );
  final String name;
  final String kind; // class | mixin | enum | fn | ext | typedef
  final int line;
  final String sig;
  final String? doc;
  final List<String>? members;

  /// Uncapped `line:name` member index when display [members] is capped.
  final List<String>? memberIndex;

  Map<String, dynamic> toJson() => {
        'n': name,
        'k': kind,
        'l': line,
        'sig': sig,
        if (doc != null) 'doc': doc,
        if (members != null) 'members': members,
        if (memberIndex != null) 'mi': memberIndex,
      };
}

String _collapseWs(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

int lineOf(LineInfo lineInfo, int offset) =>
    lineInfo.getLocation(offset).lineNumber;

/// First line of a doc comment (stripped of `///`/`/**` markers), or `null`.
String? renderDoc(Comment? comment) {
  if (comment == null || comment.tokens.isEmpty) return null;
  var first = comment.tokens.first.lexeme;
  first = first.replaceFirst(RegExp(r'^///?\s?'), '');
  first = first.replaceFirst(RegExp(r'^/\*+\s?'), '');
  first = _collapseWs(first);
  if (first.isEmpty) return null;
  return _truncate(first, 100);
}

String renderParams(FormalParameterList? params) {
  if (params == null) return '()';
  return _truncate(_collapseWs(params.toSource()), 100);
}

/// class/mixin header: `class Foo<T> extends Bar with M implements I`.
/// Modifier prefix order matches Dart's required declaration order:
/// abstract? (sealed | base? (final | interface)?)? class.
String renderClassSig(ClassDeclaration d) {
  final buf = StringBuffer();
  if (d.abstractKeyword != null) buf.write('abstract ');
  if (d.sealedKeyword != null) buf.write('sealed ');
  if (d.baseKeyword != null) buf.write('base ');
  if (d.finalKeyword != null) buf.write('final ');
  if (d.interfaceKeyword != null) buf.write('interface ');
  buf
    ..write('class ')
    ..write(d.namePart.toSource());
  final ext = d.extendsClause;
  if (ext != null) buf.write(' ${_collapseWs(ext.toSource())}');
  final wth = d.withClause;
  if (wth != null) buf.write(' ${_collapseWs(wth.toSource())}');
  final impl = d.implementsClause;
  if (impl != null) buf.write(' ${_collapseWs(impl.toSource())}');
  return _truncate(_collapseWs(buf.toString()), 140);
}

String renderMixinSig(MixinDeclaration d) {
  final buf = StringBuffer()..write('mixin ${d.name.lexeme}');
  final tp = d.typeParameters;
  if (tp != null) buf.write(tp.toSource());
  final on = d.onClause;
  if (on != null) buf.write(' ${_collapseWs(on.toSource())}');
  final impl = d.implementsClause;
  if (impl != null) buf.write(' ${_collapseWs(impl.toSource())}');
  return _truncate(_collapseWs(buf.toString()), 140);
}

/// enum header: `enum Foo with M implements I { v1, v2, v3 }` — first 8
/// values then `, …`.
String renderEnumSig(EnumDeclaration d) {
  final values = d.body.constants.map((c) => c.name.lexeme).toList();
  final shown = values.take(8).join(', ');
  final suffix = values.length > 8 ? ', …' : '';
  final buf = StringBuffer()..write('enum ${d.namePart.toSource()}');
  final wth = d.withClause;
  if (wth != null) buf.write(' ${_collapseWs(wth.toSource())}');
  final impl = d.implementsClause;
  if (impl != null) buf.write(' ${_collapseWs(impl.toSource())}');
  buf.write(' { $shown$suffix }');
  return _truncate(_collapseWs(buf.toString()), 140);
}

String renderFunctionSig(FunctionDeclaration d) {
  final ret = d.returnType?.toSource();
  final params = renderParams(d.functionExpression.parameters);
  final head = ret == null ? d.name.lexeme : '$ret ${d.name.lexeme}';
  return _truncate(_collapseWs('$head$params'), 140);
}

String renderExtensionSig(ExtensionDeclaration d) {
  final name = d.name?.lexeme;
  final on = d.onClause?.extendedType.toSource();
  final head = name == null ? 'extension' : 'extension $name';
  return _truncate(
    _collapseWs(on == null ? head : '$head on $on'),
    140,
  );
}

/// extension type header: `extension type Meters(double value) implements
/// Comparable<Meters>`.
String renderExtensionTypeSig(ExtensionTypeDeclaration d) {
  final buf = StringBuffer()
    ..write('extension type ')
    ..write(d.primaryConstructor.toSource());
  final impl = d.implementsClause;
  if (impl != null) buf.write(' ${_collapseWs(impl.toSource())}');
  return _truncate(_collapseWs(buf.toString()), 140);
}

String renderTypedefSig(TypeAlias d) {
  if (d is FunctionTypeAlias) {
    final ret = d.returnType?.toSource();
    final params = renderParams(d.parameters);
    final head = ret == null ? d.name.lexeme : '$ret ${d.name.lexeme}';
    return _truncate(_collapseWs('typedef $head$params'), 140);
  }
  if (d is GenericTypeAlias) {
    return _truncate(
      _collapseWs('typedef ${d.name.lexeme} = ${d.type.toSource()}'),
      140,
    );
  }
  return _truncate(_collapseWs('typedef ${d.name.lexeme}'), 140);
}

/// True for the `"… N more"` render cap trailer from [renderMembers].
bool isMemberCapTrailer(String line) => line.startsWith('…');

/// Parse a rendered member line (`"<line>: <sig>"`) into name + line, or null.
({String name, int line})? parseRenderedMember(String memberLine) {
  final colon = memberLine.indexOf(': ');
  final line = colon > 0 ? int.tryParse(memberLine.substring(0, colon)) : null;
  final sig = colon > 0 ? memberLine.substring(colon + 2) : memberLine;
  final name = declaredMemberName(sig);
  if (name == null || line == null) return null;
  return (name: name, line: line);
}

/// The declared identifier of a member SIGNATURE string (e.g.
/// `Future<void> handleResume({...})` → `handleResume`). Returns null when no
/// identifier can be isolated.
String? declaredMemberName(String sig) {
  const ident = r'[A-Za-z_$][A-Za-z0-9_$]*';
  final acc = RegExp('\\b(?:get|set)\\s+($ident)').firstMatch(sig);
  if (acc != null) return acc.group(1);
  final call = RegExp('($ident)\\s*\\(').firstMatch(sig);
  if (call != null) return call.group(1);
  final ids = RegExp(ident).allMatches(sig).map((m) => m.group(0)!).toList();
  return ids.isEmpty ? null : ids.last;
}

/// Uncapped `line:name` entries for every public member — used by `find` when
/// [renderMembers] caps display at 12.
List<String> indexMemberNames(
  Iterable<ClassMember> members,
  LineInfo lineInfo,
  String ownerName, {
  bool includePrivate = false,
}) {
  final out = <String>[];
  for (final m in members) {
    for (final line in renderMember(
      m,
      lineInfo,
      ownerName,
      includePrivate: includePrivate,
    )) {
      final parsed = parseRenderedMember(line);
      if (parsed != null) out.add('${parsed.line}: ${parsed.name}');
    }
  }
  return out;
}

/// One member line (`"<line>: <sig>"`), or `const []` for a private/skipped
/// member when `includePrivate` is `false` (the default; symbol-record use).
/// `constructorName` = the enclosing class/mixin/enum name, needed to render
/// unnamed constructors as `Name(...)`.
List<String> renderMember(
  ClassMember m,
  LineInfo lineInfo,
  String constructorName, {
  bool includePrivate = false,
}) {
  if (m is ConstructorDeclaration) {
    final name = m.name?.lexeme;
    if (!includePrivate && name != null && name.startsWith('_')) {
      return const [];
    }
    final factory = m.factoryKeyword != null ? 'factory ' : '';
    final label = name == null ? constructorName : '$constructorName.$name';
    final line = lineOf(lineInfo, m.offset);
    return ['$line: $factory$label${renderParams(m.parameters)}'];
  }
  if (m is MethodDeclaration) {
    if (!includePrivate && m.name.lexeme.startsWith('_')) return const [];
    final line = lineOf(lineInfo, m.offset);
    final static = m.isStatic ? 'static ' : '';
    if (m.isGetter) {
      final ret = m.returnType?.toSource();
      final type = ret == null ? '' : '$ret ';
      return ['$line: $static$type' 'get ${m.name.lexeme}'];
    }
    if (m.isSetter) {
      final params = renderParams(m.parameters);
      return ['$line: ${static}set ${m.name.lexeme}$params'];
    }
    final ret = m.returnType?.toSource();
    final params = renderParams(m.parameters);
    final operatorPrefix = m.isOperator ? 'operator ' : '';
    final name = '$operatorPrefix${m.name.lexeme}';
    final head = ret == null ? name : '$ret $name';
    return ['$line: $static$head$params'];
  }
  if (m is FieldDeclaration) {
    final type = m.fields.type?.toSource();
    final names = m.fields.variables
        .map((v) => v.name.lexeme)
        .where((n) => includePrivate || !n.startsWith('_'))
        .toList();
    if (names.isEmpty) return const [];
    final line = lineOf(lineInfo, m.offset);
    final static = m.isStatic ? 'static ' : '';
    final modifier = m.fields.isConst
        ? 'const'
        : m.fields.isFinal
            ? 'final'
            : 'var';
    final typeStr = type == null ? '' : '$type ';
    return ['$line: $static$modifier $typeStr${names.join(', ')}'];
  }
  return const [];
}

/// Members in source order, capped at 12 + a `"… N more"` trailer. Public
/// only by default; pass `includePrivate: true` to keep private members too
/// (skeleton use). Returns `null` when there are none (caller omits the
/// `members` key).
List<String>? renderMembers(
  Iterable<ClassMember> members,
  LineInfo lineInfo,
  String ownerName, {
  bool includePrivate = false,
}) {
  final out = <String>[];
  for (final m in members) {
    out.addAll(
      renderMember(m, lineInfo, ownerName, includePrivate: includePrivate),
    );
  }
  if (out.isEmpty) return null;
  if (out.length > 12) {
    final extra = out.length - 12;
    return [...out.take(12), '… $extra more'];
  }
  return out;
}
