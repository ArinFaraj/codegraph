// The vocabulary both halves of codegraph share: what a declaration is, what
// a directive does, and how a use reads. Labels are what people and JSON see.

enum DeclKind {
  classDecl('class'),
  mixinClass('mixin class'),
  mixin('mixin'),
  enumDecl('enum'),
  extension('extension'),
  extensionType('extension type'),
  typedef('typedef'),
  function('function'),
  getter('getter'),
  setter('setter'),
  variable('variable'),
  provider('provider'),
  constructor('constructor'),
  method('method'),
  field('field'),
  enumValue('enum value'),
  parameter('parameter'),
  localVariable('local variable'),
  localFunction('local function'),
  typeParameter('type parameter'),
  other('declaration');

  const DeclKind(this.label);
  final String label;

  @override
  String toString() => label;
}

/// An unnamed constructor: it carries its class's name, but is not what
/// that name refers to.
bool isUnnamedConstructor(DeclKind kind, String name, String? owner) =>
    kind == DeclKind.constructor && name == owner;

enum DirectiveKind {
  import('import'),
  export('export'),
  part('part'),
  partOf('part of');

  const DirectiveKind(this.label);
  final String label;

  bool get isDependency => this == import || this == export;

  @override
  String toString() => label;
}

/// How a use reads in context. Declaration order is display order: Riverpod
/// roles first, because they are what a reader of provider code asks for.
enum Role {
  refWatch('ref.watch'),
  refRead('ref.read'),
  refListen('ref.listen'),
  refInvalidate('ref.invalidate'),
  refRefresh('ref.refresh'),
  refExists('ref.exists'),
  override('override'),
  call('call'),
  construct('construct'),
  tearOff('tear-off'),
  read('read'),
  write('write'),
  namedArg('named arg'),
  type('type'),
  extend('extend'),
  implement('implement'),
  mixin('mixin'),
  on('on'),
  annotation('annotation'),
  reference('reference'),
  import('import'),
  doc('doc');

  const Role(this.label);
  final String label;

  @override
  String toString() => label;
}
