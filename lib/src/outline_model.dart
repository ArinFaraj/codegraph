// Parse-only facts about one file, as cached in .dart_tool/codegraph/.
import 'kinds.dart';

class Decl {
  Decl({
    required this.name,
    required this.kind,
    required this.line,
    required this.offset,
    required this.end,
    required this.sig,
    this.owner,
    this.doc,
    this.generated = false,
  });

  factory Decl.fromJson(Map<String, dynamic> j) => Decl(
    name: j['n'] as String,
    kind: DeclKind.values.byName(j['k'] as String),
    line: j['l'] as int,
    offset: j['o'] as int,
    end: j['e'] as int,
    sig: j['s'] as String,
    owner: j['w'] as String?,
    doc: j['d'] as String?,
    generated: j['g'] == true,
  );

  final String name;
  final DeclKind kind;
  final int line;
  final int offset;
  final int end;
  final String sig;
  final String? owner;
  final String? doc;

  /// A provider that riverpod_generator derives from an annotated declaration.
  final bool generated;

  String get qualified => owner == null ? name : '$owner.$name';
  bool get isMember => owner != null;

  Map<String, dynamic> toJson() => {
    'n': name,
    'k': kind.name,
    'l': line,
    'o': offset,
    'e': end,
    's': sig,
    'w': ?owner,
    'd': ?doc,
    if (generated) 'g': true,
  };
}

class UriDirective {
  UriDirective(this.kind, this.uri, this.line);

  factory UriDirective.fromJson(Map<String, dynamic> j) => UriDirective(
    DirectiveKind.values.byName(j['k'] as String),
    j['u'] as String,
    j['l'] as int,
  );

  final DirectiveKind kind;
  final String uri;
  final int line;

  Map<String, dynamic> toJson() => {'k': kind.name, 'u': uri, 'l': line};
}

class ProviderUse {
  ProviderUse(this.provider, this.role, this.line);

  factory ProviderUse.fromJson(Map<String, dynamic> j) => ProviderUse(
    j['p'] as String,
    Role.values.byName(j['r'] as String),
    j['l'] as int,
  );

  final String provider;
  final Role role;
  final int line;

  Map<String, dynamic> toJson() => {'p': provider, 'r': role.name, 'l': line};
}

class FileOutline {
  FileOutline({
    required this.path,
    required this.lines,
    required this.decls,
    required this.directives,
    required this.providerUses,
    required this.identifiers,
    required this.stringWords,
  });

  factory FileOutline.fromJson(String path, Map<String, dynamic> j) =>
      FileOutline(
        path: path,
        lines: j['lines'] as int,
        decls: [
          for (final d in j['decls'] as List)
            Decl.fromJson(d as Map<String, dynamic>),
        ],
        directives: [
          for (final d in j['dirs'] as List)
            UriDirective.fromJson(d as Map<String, dynamic>),
        ],
        providerUses: [
          for (final d in j['uses'] as List)
            ProviderUse.fromJson(d as Map<String, dynamic>),
        ],
        identifiers: (j['ids'] as List).cast<String>().toSet(),
        stringWords: (j['strs'] as List).cast<String>().toSet(),
      );

  /// Workspace-relative path.
  final String path;
  final int lines;
  final List<Decl> decls;
  final List<UriDirective> directives;
  final List<ProviderUse> providerUses;

  /// Identifier tokens the file contains.
  final Set<String> identifiers;

  /// Words that appear inside the file's string literals.
  final Set<String> stringWords;

  Iterable<Decl> get topLevel => decls.where((d) => !d.isMember);
  Iterable<Decl> get providers =>
      decls.where((d) => d.kind == DeclKind.provider);

  Map<String, dynamic> toJson() => {
    'lines': lines,
    'decls': [for (final d in decls) d.toJson()],
    'dirs': [for (final d in directives) d.toJson()],
    'uses': [for (final u in providerUses) u.toJson()],
    'ids': identifiers.toList()..sort(),
    'strs': stringWords.toList()..sort(),
  };
}
