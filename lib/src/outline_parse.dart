import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'declarations.dart';
import 'outline_model.dart';
import 'riverpod.dart';

FileOutline parseOutline(String path, String content) {
  final unit = parseString(content: content, throwIfDiagnostics: false).unit;
  final info = unit.lineInfo;
  int line(int offset) => info.getLocation(offset).lineNumber;

  final directives = <UriDirective?>[
    for (final d in unit.directives)
      switch (d) {
        ImportDirective() => UriDirective(
          'import',
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        ExportDirective() => UriDirective(
          'export',
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        PartDirective() => UriDirective(
          'part',
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        PartOfDirective() => UriDirective(
          'part-of',
          d.uri?.stringValue ?? d.libraryName?.toSource() ?? '',
          line(d.offset),
        ),
        _ => null,
      },
  ].nonNulls.toList();

  final decls = <Decl>[];
  for (final d in declarationsOf(unit)) {
    final node = d.node;
    final providerKind = node is VariableDeclaration && !d.isMember
        ? providerKindOf(node.initializer)
        : null;
    decls.add(
      Decl(
        name: d.name,
        kind: providerKind != null ? 'provider' : d.kind,
        line: line(d.nameOffset),
        offset: d.offset,
        end: d.end,
        sig: providerKind != null ? '${d.name} = $providerKind' : d.sig,
        owner: d.owner,
        doc: d.doc,
      ),
    );
    final annotated = switch (node) {
      FunctionDeclaration() || ClassDeclaration() when !d.isMember =>
        isRiverpodAnnotated((node as AnnotatedNode).metadata),
      _ => false,
    };
    if (annotated) {
      final name = generatedProviderName(d.name);
      decls.add(
        Decl(
          name: name,
          kind: 'provider',
          line: line(d.nameOffset),
          offset: d.offset,
          end: d.end,
          sig: '$name = @riverpod ${d.name}',
          generated: true,
        ),
      );
    }
  }

  final uses = <ProviderUse>[];
  unit.accept(_ProviderUseVisitor(uses, line));

  final ids = <String>{};
  for (Token? t = unit.beginToken; t != null && !t.isEof; t = t.next) {
    if (t.type == TokenType.IDENTIFIER) ids.add(t.lexeme);
    if (t.next == t) break;
  }

  return FileOutline(
    path: path,
    lines: info.lineCount,
    decls: decls,
    directives: directives,
    providerUses: uses,
    identifiers: ids,
  );
}

class _ProviderUseVisitor extends RecursiveAstVisitor<void> {
  _ProviderUseVisitor(this.out, this.line);

  final List<ProviderUse> out;
  final int Function(int) line;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final role = providerRoles[node.methodName.name];
    final args = node.argumentList.arguments;
    if (role != null && args.isNotEmpty) {
      final name = providerNameOf(args.first.argumentExpression);
      if (name != null) out.add(ProviderUse(name, role, line(node.offset)));
    }
    super.visitMethodInvocation(node);
  }
}
