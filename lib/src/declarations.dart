// One walk over a compilation unit's declarations, shared by the parse-only
// outline and the resolved engine. On a resolved unit each entry also knows
// its element, so resolved verbs never match declarations by name or line.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'signatures.dart';

class DeclNode {
  DeclNode({
    required this.node,
    required this.name,
    required this.kind,
    required this.nameOffset,
    required this.offset,
    required this.end,
    required this.sig,
    this.owner,
    this.doc,
    this.ownerNode,
  });

  /// The declaring node: a [VariableDeclaration] for fields and top-level
  /// variables, the declaration itself otherwise.
  final Declaration node;
  final String name;

  /// class, mixin, enum, extension, extension-type, typedef, function,
  /// getter, setter, variable, constructor, method, field, enum-value.
  final String kind;
  final int nameOffset;
  final int offset;
  final int end;
  final String sig;
  final String? owner;
  final String? doc;

  /// The enclosing type declaration of a member.
  final Declaration? ownerNode;

  bool get isMember => owner != null;
  String get qualified => owner == null ? name : '$owner.$name';

  /// Null on a parse-only unit.
  Element? get element => node.declaredFragment?.element;
}

List<DeclNode> declarationsOf(CompilationUnit unit) {
  final out = <DeclNode>[];

  void members(
    NodeList<ClassMember> list,
    String owner,
    Declaration ownerNode,
  ) {
    for (final m in list) {
      if (m is FieldDeclaration) {
        for (final v in m.fields.variables) {
          out.add(
            DeclNode(
              node: v,
              name: v.name.lexeme,
              kind: 'field',
              nameOffset: v.name.offset,
              offset: m.offset,
              end: m.end,
              sig: renderMemberSig(m, owner, field: v.name.lexeme)!,
              owner: owner,
              doc: renderDoc(m.documentationComment),
              ownerNode: ownerNode,
            ),
          );
        }
      } else if (m is ConstructorDeclaration) {
        out.add(
          DeclNode(
            node: m,
            name: m.name?.lexeme ?? owner,
            kind: 'constructor',
            nameOffset: m.name?.offset ?? m.offset,
            offset: m.offset,
            end: m.end,
            sig: renderMemberSig(m, owner)!,
            owner: owner,
            doc: renderDoc(m.documentationComment),
            ownerNode: ownerNode,
          ),
        );
      } else if (m is MethodDeclaration) {
        out.add(
          DeclNode(
            node: m,
            name: m.name.lexeme,
            kind: m.isGetter
                ? 'getter'
                : m.isSetter
                ? 'setter'
                : 'method',
            nameOffset: m.name.offset,
            offset: m.offset,
            end: m.end,
            sig: renderMemberSig(m, owner)!,
            owner: owner,
            doc: renderDoc(m.documentationComment),
            ownerNode: ownerNode,
          ),
        );
      }
    }
  }

  DeclNode top(
    Declaration d,
    String name,
    String kind,
    int nameOffset,
    String sig,
  ) => DeclNode(
    node: d,
    name: name,
    kind: kind,
    nameOffset: nameOffset,
    offset: d.offset,
    end: d.end,
    sig: sig,
    doc: renderDoc(d.documentationComment),
  );

  for (final d in unit.declarations) {
    switch (d) {
      case ClassDeclaration():
        final name = d.namePart.typeName.lexeme;
        out.add(
          top(d, name, 'class', d.namePart.typeName.offset, renderClassSig(d)),
        );
        members(d.body.members, name, d);
      case MixinDeclaration():
        final name = d.name.lexeme;
        out.add(top(d, name, 'mixin', d.name.offset, renderMixinSig(d)));
        members(d.body.members, name, d);
      case EnumDeclaration():
        final name = d.namePart.typeName.lexeme;
        out.add(
          top(d, name, 'enum', d.namePart.typeName.offset, renderEnumSig(d)),
        );
        for (final c in d.body.constants) {
          out.add(
            DeclNode(
              node: c,
              name: c.name.lexeme,
              kind: 'enum-value',
              nameOffset: c.name.offset,
              offset: c.offset,
              end: c.end,
              sig: '$name.${c.name.lexeme}',
              owner: name,
              doc: renderDoc(c.documentationComment),
              ownerNode: d,
            ),
          );
        }
        members(d.body.members, name, d);
      case ExtensionDeclaration():
        final name = d.name?.lexeme;
        out.add(
          top(
            d,
            name ?? '<unnamed extension>',
            'extension',
            d.name?.offset ?? d.offset,
            renderExtensionSig(d),
          ),
        );
        if (name != null) members(d.body.members, name, d);
      case ExtensionTypeDeclaration():
        final name = d.namePart.typeName.lexeme;
        out.add(
          top(
            d,
            name,
            'extension-type',
            d.namePart.typeName.offset,
            renderExtensionTypeSig(d),
          ),
        );
        members(d.body.members, name, d);
      case TypeAlias():
        out.add(
          top(d, d.name.lexeme, 'typedef', d.name.offset, renderTypedefSig(d)),
        );
      case FunctionDeclaration():
        final kind = d.isGetter
            ? 'getter'
            : d.isSetter
            ? 'setter'
            : 'function';
        out.add(
          top(d, d.name.lexeme, kind, d.name.offset, renderFunctionSig(d)),
        );
      case TopLevelVariableDeclaration():
        for (final v in d.variables.variables) {
          out.add(
            DeclNode(
              node: v,
              name: v.name.lexeme,
              kind: 'variable',
              nameOffset: v.name.offset,
              offset: d.offset,
              end: d.end,
              sig: renderVariableSig(d, v),
              doc: renderDoc(d.documentationComment),
            ),
          );
        }
      default:
        break;
    }
  }
  return out;
}
