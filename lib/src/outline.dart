// Parse-only facts about every analyzed file: declarations, directives,
// syntactic provider declarations and uses, and the identifiers each file
// mentions. Exact for what a file says about itself; it never claims to know
// what an identifier resolves to. Cached in .dart_tool/codegraph/outline.json.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'signatures.dart';
import 'workspace.dart';

const _cacheVersion = 5;

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
    kind: j['k'] as String,
    line: j['l'] as int,
    offset: j['o'] as int,
    end: j['e'] as int,
    sig: j['s'] as String,
    owner: j['w'] as String?,
    doc: j['d'] as String?,
  );

  final String name;

  /// class, mixin, enum, extension, extension-type, typedef, function,
  /// variable, provider, constructor, method, getter, setter, field,
  /// enum-value.
  final String kind;
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
    'k': kind,
    'l': line,
    'o': offset,
    'e': end,
    's': sig,
    if (owner != null) 'w': owner,
    if (doc != null) 'd': doc,
  };
}

class Directive {
  Directive(this.kind, this.uri, this.line);

  factory Directive.fromJson(Map<String, dynamic> j) =>
      Directive(j['k'] as String, j['u'] as String, j['l'] as int);

  /// import, export, part, part-of.
  final String kind;
  final String uri;
  final int line;

  Map<String, dynamic> toJson() => {'k': kind, 'u': uri, 'l': line};
}

class ProviderUse {
  ProviderUse(this.provider, this.role, this.line);

  factory ProviderUse.fromJson(Map<String, dynamic> j) =>
      ProviderUse(j['p'] as String, j['r'] as String, j['l'] as int);

  final String provider;
  final String role;
  final int line;

  Map<String, dynamic> toJson() => {'p': provider, 'r': role, 'l': line};
}

class FileOutline {
  FileOutline({
    required this.path,
    required this.lines,
    required this.decls,
    required this.directives,
    required this.providerUses,
    required this.identifiers,
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
            Directive.fromJson(d as Map<String, dynamic>),
        ],
        providerUses: [
          for (final d in j['uses'] as List)
            ProviderUse.fromJson(d as Map<String, dynamic>),
        ],
        identifiers: (j['ids'] as List).cast<String>().toSet(),
      );

  /// Workspace-relative path.
  final String path;
  final int lines;
  final List<Decl> decls;
  final List<Directive> directives;
  final List<ProviderUse> providerUses;
  final Set<String> identifiers;

  Iterable<Decl> get topLevel => decls.where((d) => !d.isMember);
  Iterable<Decl> get providers => decls.where((d) => d.kind == 'provider');

  Map<String, dynamic> toJson() => {
    'lines': lines,
    'decls': [for (final d in decls) d.toJson()],
    'dirs': [for (final d in directives) d.toJson()],
    'uses': [for (final u in providerUses) u.toJson()],
    'ids': identifiers.toList()..sort(),
  };

  /// The innermost declaration whose span holds [offset].
  Decl? enclosing(int offset) {
    Decl? best;
    for (final d in decls) {
      if (d.offset <= offset && offset < d.end) {
        if (best == null || d.offset >= best.offset) best = d;
      }
    }
    return best;
  }
}

FileOutline parseOutline(String path, String content) {
  final unit = parseString(content: content, throwIfDiagnostics: false).unit;
  final info = unit.lineInfo;
  int line(int offset) => lineOf(info, offset);
  final decls = <Decl>[];
  final directives = <Directive>[];

  for (final d in unit.directives) {
    if (d is ImportDirective) {
      directives.add(
        Directive('import', d.uri.stringValue ?? '', line(d.offset)),
      );
    } else if (d is ExportDirective) {
      directives.add(
        Directive('export', d.uri.stringValue ?? '', line(d.offset)),
      );
    } else if (d is PartDirective) {
      directives.add(
        Directive('part', d.uri.stringValue ?? '', line(d.offset)),
      );
    } else if (d is PartOfDirective) {
      directives.add(
        Directive(
          'part-of',
          d.uri?.stringValue ?? d.libraryName?.toSource() ?? '',
          line(d.offset),
        ),
      );
    }
  }

  void members(NodeList<ClassMember> list, String owner) {
    for (final m in list) {
      if (m is FieldDeclaration) {
        for (final v in m.fields.variables) {
          decls.add(
            Decl(
              name: v.name.lexeme,
              kind: 'field',
              line: line(v.name.offset),
              offset: m.offset,
              end: m.end,
              sig: renderMemberSig(m, owner, field: v.name.lexeme)!,
              owner: owner,
              doc: renderDoc(m.documentationComment),
            ),
          );
        }
        continue;
      }
      final sig = renderMemberSig(m, owner);
      if (sig == null) continue;
      String name;
      String kind;
      int nameOffset;
      if (m is ConstructorDeclaration) {
        name = m.name?.lexeme ?? owner;
        kind = 'constructor';
        nameOffset = m.name?.offset ?? m.offset;
      } else if (m is MethodDeclaration) {
        name = m.name.lexeme;
        kind = m.isGetter
            ? 'getter'
            : m.isSetter
            ? 'setter'
            : 'method';
        nameOffset = m.name.offset;
      } else {
        continue;
      }
      decls.add(
        Decl(
          name: name,
          kind: kind,
          line: line(nameOffset),
          offset: m.offset,
          end: m.end,
          sig: sig,
          owner: owner,
          doc: renderDoc(m.documentationComment),
        ),
      );
    }
  }

  for (final d in unit.declarations) {
    final doc = renderDoc(d.documentationComment);
    if (d is ClassDeclaration) {
      final name = d.namePart.typeName.lexeme;
      decls.add(
        Decl(
          name: name,
          kind: 'class',
          line: line(d.namePart.offset),
          offset: d.offset,
          end: d.end,
          sig: renderClassSig(d),
          doc: doc,
        ),
      );
      if (_riverpodAnnotated(d.metadata)) {
        decls.add(_generatedProvider(name, d, line(d.namePart.offset)));
      }
      members(d.body.members, name);
    } else if (d is MixinDeclaration) {
      decls.add(
        Decl(
          name: d.name.lexeme,
          kind: 'mixin',
          line: line(d.name.offset),
          offset: d.offset,
          end: d.end,
          sig: renderMixinSig(d),
          doc: doc,
        ),
      );
      members(d.body.members, d.name.lexeme);
    } else if (d is EnumDeclaration) {
      final name = d.namePart.typeName.lexeme;
      decls.add(
        Decl(
          name: name,
          kind: 'enum',
          line: line(d.namePart.offset),
          offset: d.offset,
          end: d.end,
          sig: renderEnumSig(d),
          doc: doc,
        ),
      );
      for (final c in d.body.constants) {
        decls.add(
          Decl(
            name: c.name.lexeme,
            kind: 'enum-value',
            line: line(c.name.offset),
            offset: c.offset,
            end: c.end,
            sig: '$name.${c.name.lexeme}',
            owner: name,
            doc: renderDoc(c.documentationComment),
          ),
        );
      }
      members(d.body.members, name);
    } else if (d is ExtensionDeclaration) {
      final name = d.name?.lexeme;
      decls.add(
        Decl(
          name: name ?? '<unnamed extension>',
          kind: 'extension',
          line: line(d.offset),
          offset: d.offset,
          end: d.end,
          sig: renderExtensionSig(d),
          doc: doc,
        ),
      );
      if (name != null) members(d.body.members, name);
    } else if (d is ExtensionTypeDeclaration) {
      final name = d.namePart.typeName.lexeme;
      decls.add(
        Decl(
          name: name,
          kind: 'extension-type',
          line: line(d.namePart.typeName.offset),
          offset: d.offset,
          end: d.end,
          sig: renderExtensionTypeSig(d),
          doc: doc,
        ),
      );
      members(d.body.members, name);
    } else if (d is TypeAlias) {
      decls.add(
        Decl(
          name: d.name.lexeme,
          kind: 'typedef',
          line: line(d.name.offset),
          offset: d.offset,
          end: d.end,
          sig: renderTypedefSig(d),
          doc: doc,
        ),
      );
    } else if (d is FunctionDeclaration) {
      decls.add(
        Decl(
          name: d.name.lexeme,
          kind: d.isGetter
              ? 'getter'
              : d.isSetter
              ? 'setter'
              : 'function',
          line: line(d.name.offset),
          offset: d.offset,
          end: d.end,
          sig: renderFunctionSig(d),
          doc: doc,
        ),
      );
      if (_riverpodAnnotated(d.metadata)) {
        decls.add(_generatedProvider(d.name.lexeme, d, line(d.name.offset)));
      }
    } else if (d is TopLevelVariableDeclaration) {
      for (final v in d.variables.variables) {
        final providerKind = _providerKind(v.initializer);
        decls.add(
          Decl(
            name: v.name.lexeme,
            kind: providerKind != null ? 'provider' : 'variable',
            line: line(v.name.offset),
            offset: d.offset,
            end: d.end,
            sig: providerKind != null
                ? '${v.name.lexeme} = $providerKind'
                : renderVariableSig(d, v),
            doc: doc,
          ),
        );
      }
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

bool _riverpodAnnotated(NodeList<Annotation> metadata) => metadata.any((a) {
  final n = a.name.name;
  return n == 'riverpod' || n == 'Riverpod';
});

Decl _generatedProvider(String sourceName, AstNode node, int line) {
  final base = sourceName.startsWith('_')
      ? sourceName.substring(1)
      : sourceName;
  final name = '${base[0].toLowerCase()}${base.substring(1)}Provider';
  return Decl(
    name: name,
    kind: 'provider',
    line: line,
    offset: node.offset,
    end: node.end,
    sig: '$name = @riverpod $sourceName',
  );
}

/// `NotifierProvider.autoDispose`, `FutureProvider.family` and friends, when a
/// top-level initializer constructs a Riverpod provider.
String? _providerKind(Expression? init) {
  if (init == null) return null;
  var head = init.toSource();
  final paren = head.indexOf('(');
  if (paren > 0) head = head.substring(0, paren);
  final lt = head.indexOf('<');
  final base = lt > 0 ? head.substring(0, lt) : head;
  final first = base.split('.').first;
  if (!RegExp(r'^[A-Z]\w*$').hasMatch(first) || !first.endsWith('Provider')) {
    return null;
  }
  return base.replaceAll(RegExp(r'\s+'), '');
}

const providerRoles = {
  'watch': 'ref.watch',
  'read': 'ref.read',
  'listen': 'ref.listen',
  'listenManual': 'ref.listen',
  'invalidate': 'ref.invalidate',
  'refresh': 'ref.refresh',
  'exists': 'ref.exists',
};

class _ProviderUseVisitor extends RecursiveAstVisitor<void> {
  _ProviderUseVisitor(this.out, this.line);

  final List<ProviderUse> out;
  final int Function(int) line;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final role = providerRoles[node.methodName.name];
    if (role != null && node.argumentList.arguments.isNotEmpty) {
      final name = providerNameOf(
        node.argumentList.arguments.first.argumentExpression,
      );
      if (name != null) out.add(ProviderUse(name, role, line(node.offset)));
    }
    super.visitMethodInvocation(node);
  }
}

/// `fooProvider` from `fooProvider`, `fooProvider(arg)`,
/// `fooProvider.notifier`, `fooProvider.select(...)`, `p.fooProvider`.
String? providerNameOf(Expression e) {
  var x = e;
  while (true) {
    if (x is MethodInvocation) {
      final target = x.target;
      if (target == null) {
        return x.methodName.name.endsWith('Provider')
            ? x.methodName.name
            : null;
      }
      if (x.methodName.name.endsWith('Provider')) return x.methodName.name;
      x = target;
    } else if (x is FunctionExpressionInvocation) {
      x = x.function;
    } else if (x is PropertyAccess) {
      if (x.propertyName.name.endsWith('Provider')) return x.propertyName.name;
      final target = x.target;
      if (target == null) return null;
      x = target;
    } else if (x is PrefixedIdentifier) {
      if (x.identifier.name.endsWith('Provider')) return x.identifier.name;
      if (x.prefix.name.endsWith('Provider')) return x.prefix.name;
      return null;
    } else if (x is SimpleIdentifier) {
      return x.name.endsWith('Provider') ? x.name : null;
    } else if (x is ParenthesizedExpression) {
      x = x.expression;
    } else {
      return null;
    }
  }
}

/// Every analyzed file's outline, refreshed from disk on load.
class OutlineIndex {
  OutlineIndex._(this.workspace, this.files, this._packageRoots);

  final Workspace workspace;

  /// Keyed by workspace-relative path.
  final Map<String, FileOutline> files;
  final Map<String, String> _packageRoots;

  Map<String, List<String>>? _importers;

  static OutlineIndex load(Workspace ws, {List<String>? analyzedFiles}) {
    final cacheFile = File('${ws.stateDir}/outline.json');
    Map<String, dynamic> cache = const {};
    if (cacheFile.existsSync()) {
      try {
        final j = jsonDecode(cacheFile.readAsStringSync());
        if (j is Map<String, dynamic> && j['v'] == _cacheVersion) cache = j;
      } catch (_) {}
    }
    final cachedFiles = (cache['files'] as Map<String, dynamic>?) ?? const {};
    final dirStamps = (cache['dirs'] as Map<String, dynamic>?) ?? const {};

    List<String>? fileList = analyzedFiles;
    if (fileList == null && dirStamps.isNotEmpty) {
      var dirsUnchanged = true;
      for (final e in dirStamps.entries) {
        if (_dirStamp(e.key) != e.value) {
          dirsUnchanged = false;
          break;
        }
      }
      if (dirsUnchanged) {
        fileList = [for (final k in cachedFiles.keys) ws.absolute(k)];
      }
    }
    fileList ??= ws.analyzedFiles();

    final files = <String, FileOutline>{};
    final newCache = <String, dynamic>{};
    var dirty = cachedFiles.length != fileList.length;
    for (final abs in fileList) {
      final rel = ws.relative(abs);
      final stat = FileStat.statSync(abs);
      if (stat.type == FileSystemEntityType.notFound) {
        dirty = true;
        continue;
      }
      final stamp = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
      final cached = cachedFiles[rel];
      if (cached is Map<String, dynamic> && cached['t'] == stamp) {
        files[rel] = FileOutline.fromJson(
          rel,
          cached['o'] as Map<String, dynamic>,
        );
        newCache[rel] = cached;
        continue;
      }
      dirty = true;
      String content;
      try {
        content = File(abs).readAsStringSync();
      } catch (_) {
        continue;
      }
      final outline = parseOutline(rel, content);
      files[rel] = outline;
      newCache[rel] = {'t': stamp, 'o': outline.toJson()};
    }
    if (dirty) {
      final dirs = <String, String>{};
      for (final abs in fileList) {
        final dir = abs.substring(0, abs.lastIndexOf('/'));
        dirs.putIfAbsent(dir, () => _dirStamp(dir));
      }
      try {
        Directory(ws.stateDir).createSync(recursive: true);
        final tmp = File('${cacheFile.path}.$pid.tmp');
        tmp.writeAsStringSync(
          jsonEncode({'v': _cacheVersion, 'dirs': dirs, 'files': newCache}),
        );
        tmp.renameSync(cacheFile.path);
      } catch (_) {}
    }
    return OutlineIndex._(ws, files, ws.packageRoots());
  }

  /// Resolves an import/export/part URI written in [fromRel] to a
  /// workspace-relative path, or null when it points outside the workspace.
  String? resolveUri(String fromRel, String uri) {
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final rest = uri.substring(8);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final root = _packageRoots[rest.substring(0, slash)];
      if (root == null) return null;
      final rel = workspace.relative(
        workspace.absolute('$root/lib/${rest.substring(slash + 1)}'),
      );
      return files.containsKey(rel) ? rel : null;
    }
    final dir = fromRel.contains('/')
        ? fromRel.substring(0, fromRel.lastIndexOf('/'))
        : '';
    final rel = workspace.relative(
      workspace.absolute(dir.isEmpty ? uri : '$dir/$uri'),
    );
    return files.containsKey(rel) ? rel : null;
  }

  /// Files this file imports or exports, resolved inside the workspace.
  List<(String, Directive)> dependencies(String rel) {
    final f = files[rel];
    if (f == null) return const [];
    return [
      for (final d in f.directives)
        if (d.kind == 'import' || d.kind == 'export')
          if (resolveUri(rel, d.uri) case final target?) (target, d),
    ];
  }

  /// Files that import or export [rel].
  List<String> importers(String rel) {
    final map = _importers ??= () {
      final m = <String, List<String>>{};
      for (final from in files.keys) {
        for (final (to, _) in dependencies(from)) {
          (m[to] ??= []).add(from);
        }
      }
      for (final l in m.values) {
        l.sort();
      }
      return m;
    }();
    return map[rel] ?? const [];
  }

  /// Number of files other than [exceptFile] whose tokens mention [name].
  int mentions(String name, {String? exceptFile}) {
    var n = 0;
    for (final f in files.values) {
      if (f.path != exceptFile && f.identifiers.contains(name)) n++;
    }
    return n;
  }
}

String _dirStamp(String dir) {
  final s = FileStat.statSync(dir);
  return s.type == FileSystemEntityType.notFound
      ? 'missing'
      : '${s.modified.microsecondsSinceEpoch}';
}
