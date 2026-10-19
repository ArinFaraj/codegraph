// `show <file>` and `show <dir>`: a file's outline and wiring, and a
// directory's digest with its notes, from the parse-only outline.
import 'dart:collection';
import 'dart:io';

import 'kinds.dart';
import 'outline.dart';
import 'result.dart';
import 'workspace.dart';

class ShowFileAnswer extends Answer {
  ShowFileAnswer(this.outline, this.imports, this.external, this.importers);

  final FileOutline outline;
  final List<(String, UriDirective)> imports;
  final List<String> external;
  final List<String> importers;

  @override
  String get verb => 'show';

  Iterable<Decl> get _shown => outline.decls.where((d) => !d.generated);

  @override
  void write(TextOut out) {
    out.header('${outline.path}  (${outline.lines} lines)');
    out.section('outline:');
    for (final d in _shown) {
      out.row('${d.isMember ? '    ' : '  '}${d.line}: ${d.sig}');
    }
    out.section(
      'imports (${imports.length} in workspace, ${external.length} external):',
    );
    for (final (target, d) in imports) {
      out.row(
        '  ${d.line}: $target${d.kind == DirectiveKind.export ? '  (export)' : ''}',
      );
    }
    out.section('imported by (${importers.length}):');
    for (final p in importers) {
      out.row('  $p');
    }
    final providers = outline.providers.toList();
    if (providers.isNotEmpty) {
      out.section('providers declared:');
      for (final p in providers) {
        out.row('  ${p.line}: ${p.sig}');
      }
    }
    if (outline.providerUses.isNotEmpty) {
      out.section('provider uses:');
      for (final u in outline.providerUses) {
        out.row('  ${u.line}: ${u.role}(${u.provider})');
      }
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'file',
    'path': outline.path,
    'lines': outline.lines,
    'declarations': [for (final d in _shown) d.toJson()],
    'imports': [
      for (final (t, d) in imports)
        {'path': t, 'line': d.line, 'kind': d.kind.label},
    ],
    'externalImports': external,
    'importedBy': importers,
    'providers': [for (final p in outline.providers) p.toJson()],
    'providerUses': [for (final u in outline.providerUses) u.toJson()],
  };
}

ShowFileAnswer showFile(OutlineIndex idx, String rel) {
  final f = idx.files[rel]!;
  return ShowFileAnswer(f, idx.dependencies(rel), [
    for (final d in f.directives)
      if (d.kind == DirectiveKind.import && idx.resolveUri(rel, d.uri) == null)
        d.uri,
  ], idx.importers(rel));
}

class ShowAreaAnswer extends Answer {
  ShowAreaAnswer({
    required this.dir,
    required this.files,
    required this.pages,
    required this.providers,
    required this.usedOutside,
    required this.consumed,
    required this.notesPath,
    required this.notes,
  });

  final String dir;
  final int files;
  final List<(Decl, String)> pages;

  /// Provider, file, number of other files mentioning it.
  final List<(Decl, String, int)> providers;
  final List<(Decl, String, int)> usedOutside;

  /// Provider name to the file declaring it, outside this area.
  final Map<String, String> consumed;
  final String? notesPath;
  final List<String> notes;

  @override
  String get verb => 'show';

  @override
  void write(TextOut out) {
    out.header(
      '$dir  (${plural(files, 'file')}, ${plural(providers.length, 'provider')})',
    );
    if (pages.isNotEmpty) {
      out.section('pages:');
      for (final (d, path) in pages) {
        out.row('  ${d.name}  $path:${d.line}');
      }
    }
    if (providers.isNotEmpty) {
      out.section('providers (by files mentioning them):');
      for (final (p, path, n) in providers) {
        out.row('  ${p.name}  $path:${p.line}  ($n)');
      }
    }
    if (usedOutside.isNotEmpty) {
      out.section('most used outside $dir (files mentioning them):');
      for (final (d, path, n) in usedOutside) {
        out.row('  ${d.kind} ${d.name}  $path:${d.line}  ($n)');
      }
    }
    if (consumed.isNotEmpty) {
      out.section('providers used from other areas:');
      for (final e in consumed.entries) {
        out.row('  ${e.key}  ${e.value}');
      }
    }
    if (notesPath != null) {
      out.footer('notes ($notesPath, ${notes.length} lines):');
      for (final l in notes.take(40)) {
        out.footer('  $l');
      }
      if (notes.length > 40) out.footer('  ... read the file for the rest');
    }
  }

  @override
  Map<String, Object?> toJson() {
    Map<String, Object?> decl(Decl d, String path, [int? n]) => {
      'name': d.name,
      'kind': d.kind.label,
      'path': path,
      'line': d.line,
      'mentionedBy': ?n,
    };
    return {
      'kind': 'area',
      'path': dir,
      'files': files,
      'pages': [for (final (d, p) in pages) decl(d, p)],
      'providers': [for (final (d, p, n) in providers) decl(d, p, n)],
      'usedOutside': [for (final (d, p, n) in usedOutside) decl(d, p, n)],
      'consumed': consumed,
      'notes': ?notesPath,
    };
  }
}

ShowAreaAnswer showArea(OutlineIndex idx, String dir) {
  final lib =
      idx.files.values
          .where(
            (f) =>
                f.path.startsWith('$dir/') &&
                !isGeneratedFile(f.path) &&
                !isTestPath(f.path),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  int outside(String name) => idx.files.values
      .where((f) => !f.path.startsWith('$dir/') && f.identifiers.contains(name))
      .length;

  final providers = [
    for (final f in lib)
      for (final p in f.providers)
        (p, f.path, idx.mentions(p.name, exceptFile: f.path)),
  ]..sort((a, b) => b.$3.compareTo(a.$3));
  final declaredHere = {for (final (p, _, _) in providers) p.name};
  final providerHome = {
    for (final f in idx.files.values)
      for (final p in f.providers) p.name: f.path,
  };
  final consumed = SplayTreeMap<String, String>();
  for (final f in lib) {
    for (final u in f.providerUses) {
      final home = providerHome[u.provider];
      if (home != null && !declaredHere.contains(u.provider)) {
        consumed[u.provider] = home;
      }
    }
  }
  final notes = _notesFor(idx.workspace, dir);
  return ShowAreaAnswer(
    dir: dir,
    files: lib.length,
    pages: [
      for (final f in lib)
        for (final d in f.topLevel)
          if (d.kind == DeclKind.classDecl &&
              !d.name.startsWith('_') &&
              (d.name.endsWith('Page') || d.name.endsWith('Screen')))
            (d, f.path),
    ],
    providers: providers,
    usedOutside:
        ([
                for (final f in lib)
                  for (final d in f.topLevel)
                    if (!d.name.startsWith('_') && d.kind != DeclKind.provider)
                      (d, f.path, outside(d.name)),
              ].where((s) => s.$3 > 0).toList()
              ..sort((a, b) => b.$3.compareTo(a.$3)))
            .take(15)
            .toList(),
    consumed: consumed,
    notesPath: notes == null ? null : idx.workspace.relative(notes),
    notes: notes == null ? const [] : File(notes).readAsLinesSync(),
  );
}

String? _notesFor(Workspace ws, String dir) {
  final name = dir.split('/').last;
  for (final candidate in [
    '${ws.root}/docs/maps/notes/$name.md',
    '${ws.root}/docs/notes/$name.md',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
