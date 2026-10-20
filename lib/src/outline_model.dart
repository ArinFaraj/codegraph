// Parse-only facts about one file, as cached in .dart_tool/codegraph/: what
// it declares and which files it names. Nothing here depends on resolution.
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
  );

  final String name;
  final DeclKind kind;
  final int line;
  final int offset;
  final int end;
  final String sig;
  final String? owner;
  final String? doc;

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

class FileOutline {
  FileOutline({
    required this.path,
    required this.lines,
    required this.decls,
    required this.directives,
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
      );

  /// Workspace-relative path.
  final String path;
  final int lines;
  final List<Decl> decls;
  final List<UriDirective> directives;

  Iterable<Decl> get topLevel => decls.where((d) => !d.isMember);

  Map<String, dynamic> toJson() => {
    'lines': lines,
    'decls': [for (final d in decls) d.toJson()],
    'dirs': [for (final d in directives) d.toJson()],
  };
}
