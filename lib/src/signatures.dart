import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 3)}...';

int lineOf(LineInfo lineInfo, int offset) =>
    lineInfo.getLocation(offset).lineNumber;

/// First sentence-ish line of a doc comment, or null.
String? renderDoc(Comment? comment) {
  if (comment == null || comment.tokens.isEmpty) return null;
  var first = comment.tokens.first.lexeme;
  first = first.replaceFirst(RegExp(r'^///?\s?'), '');
  first = first.replaceFirst(RegExp(r'^/\*+\s?'), '');
  first = _collapse(first);
  return first.isEmpty ? null : _cap(first, 100);
}

String renderParams(FormalParameterList? params) =>
    params == null ? '()' : _cap(_collapse(params.toSource()), 100);

String renderClassSig(ClassDeclaration d) {
  final buf = StringBuffer();
  if (d.abstractKeyword != null) buf.write('abstract ');
  if (d.sealedKeyword != null) buf.write('sealed ');
  if (d.baseKeyword != null) buf.write('base ');
  if (d.finalKeyword != null) buf.write('final ');
  if (d.interfaceKeyword != null) buf.write('interface ');
  if (d.mixinKeyword != null) buf.write('mixin ');
  buf.write('class ${d.namePart.toSource()}');
  for (final clause in [d.extendsClause, d.withClause, d.implementsClause]) {
    if (clause != null) buf.write(' ${_collapse(clause.toSource())}');
  }
  return _cap(_collapse(buf.toString()), 140);
}

String renderMixinSig(MixinDeclaration d) {
  final buf = StringBuffer('mixin ${d.name.lexeme}');
  if (d.typeParameters case final tp?) buf.write(tp.toSource());
  for (final clause in [d.onClause, d.implementsClause]) {
    if (clause != null) buf.write(' ${_collapse(clause.toSource())}');
  }
  return _cap(_collapse(buf.toString()), 140);
}

String renderEnumSig(EnumDeclaration d) {
  final values = d.body.constants.map((c) => c.name.lexeme).toList();
  final shown = values.take(8).join(', ');
  final more = values.length > 8 ? ', ...' : '';
  final buf = StringBuffer('enum ${d.namePart.toSource()}');
  for (final clause in [d.withClause, d.implementsClause]) {
    if (clause != null) buf.write(' ${_collapse(clause.toSource())}');
  }
  buf.write(' { $shown$more }');
  return _cap(_collapse(buf.toString()), 140);
}

String renderFunctionSig(FunctionDeclaration d) {
  final ret = d.returnType?.toSource();
  final params = renderParams(d.functionExpression.parameters);
  final accessor = d.isGetter
      ? 'get '
      : d.isSetter
      ? 'set '
      : '';
  final head = '$accessor${d.name.lexeme}';
  return _cap(
    _collapse(ret == null ? '$head$params' : '$ret $head$params'),
    140,
  );
}

String renderExtensionSig(ExtensionDeclaration d) {
  final name = d.name?.lexeme;
  final on = d.onClause?.extendedType.toSource();
  final head = name == null ? 'extension' : 'extension $name';
  return _cap(_collapse(on == null ? head : '$head on $on'), 140);
}

String renderExtensionTypeSig(ExtensionTypeDeclaration d) {
  final buf = StringBuffer('extension type ${d.namePart.toSource()}');
  if (d.implementsClause case final impl?) {
    buf.write(' ${_collapse(impl.toSource())}');
  }
  return _cap(_collapse(buf.toString()), 140);
}

String renderTypedefSig(TypeAlias d) {
  if (d is FunctionTypeAlias) {
    final ret = d.returnType?.toSource();
    final head = ret == null ? d.name.lexeme : '$ret ${d.name.lexeme}';
    return _cap(_collapse('typedef $head${renderParams(d.parameters)}'), 140);
  }
  if (d is GenericTypeAlias) {
    return _cap(
      _collapse('typedef ${d.name.lexeme} = ${d.type.toSource()}'),
      140,
    );
  }
  return 'typedef ${d.name.lexeme}';
}

String renderVariableSig(TopLevelVariableDeclaration d, VariableDeclaration v) {
  final list = d.variables;
  final modifier = list.isConst
      ? 'const '
      : list.isFinal
      ? 'final '
      : list.lateKeyword != null
      ? 'late '
      : 'var ';
  final type = list.type == null ? '' : '${list.type!.toSource()} ';
  final init = v.initializer;
  final rhs = init == null ? '' : ' = ${_cap(_collapse(init.toSource()), 80)}';
  return _cap(_collapse('$modifier$type${v.name.lexeme}$rhs'), 140);
}

/// Signature of a class member, or null for members with nothing to show.
String? renderMemberSig(ClassMember m, String ownerName, {String? field}) {
  if (m is ConstructorDeclaration) {
    final name = m.name?.lexeme;
    final factory = m.factoryKeyword != null ? 'factory ' : '';
    final konst = m.constKeyword != null ? 'const ' : '';
    final label = name == null ? ownerName : '$ownerName.$name';
    return '$konst$factory$label${renderParams(m.parameters)}';
  }
  if (m is MethodDeclaration) {
    final static = m.isStatic ? 'static ' : '';
    final ret = m.returnType?.toSource();
    final type = ret == null ? '' : '$ret ';
    if (m.isGetter) return '$static${type}get ${m.name.lexeme}';
    if (m.isSetter) {
      return '${static}set ${m.name.lexeme}${renderParams(m.parameters)}';
    }
    final op = m.isOperator ? 'operator ' : '';
    return _cap(
      _collapse('$static$type$op${m.name.lexeme}${renderParams(m.parameters)}'),
      140,
    );
  }
  if (m is FieldDeclaration) {
    final static = m.isStatic ? 'static ' : '';
    final list = m.fields;
    final modifier = list.isConst
        ? 'const '
        : list.isFinal
        ? 'final '
        : list.lateKeyword != null
        ? 'late '
        : '';
    final type = list.type == null ? '' : '${list.type!.toSource()} ';
    return '$static$modifier$type${field ?? list.variables.first.name.lexeme}';
  }
  return null;
}
