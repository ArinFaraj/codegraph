// `show <file>` and `show <dir>`: a file's outline and wiring, and a
// directory's digest with its notes. Structure comes from the outline;
// which declarations are providers, and who reads them, from resolution.
import 'dart:collection';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'args.dart';
import 'classify.dart';
import 'declarations.dart';
import 'engine.dart';
import 'kinds.dart';
import 'outline.dart';
import 'result.dart';
import 'riverpod.dart';
import 'symbols.dart';
import 'workspace.dart';

/// `show` of the file or directory [arg] names, or null when it names a
/// symbol.
Future<Answer?> showPath(Engine engine, String arg) async =>
    switch (classifyArg(engine.outline, arg, directories: true)) {
      FileArg(:final path) => await showFile(engine, path),
      DirArg(:final path) => await showArea(engine, path),
      ChoiceArg(:final candidates) => FileChoiceAnswer('show', arg, candidates),
      SymbolArg() => null,
    };

/// A provider read in a file: the use and the provider it reads.
typedef ProviderRead = (Use use, Target provider);

/// The providers [path] declares, and every place it refers to one with the
/// role each use plays, from one resolution of the file.
Future<(List<Target>, List<ProviderRead>)> providersIn(
  Engine engine,
  String path,
) async {
  final unit = await engine.analysis.unit(path);
  if (unit == null) return (const <Target>[], const <ProviderRead>[]);
  final found = <SimpleIdentifier, Element>{};
  unit.unit.accept(_ProviderReferences(found));
  return (
    [
      for (final d in declarationsOf(unit.unit))
        if (d.element case final e? when isProvider(e))
          ?targetOf(engine.analysis, e),
    ],
    [
      for (final MapEntry(key: node, value: provider) in found.entries)
        if (targetOf(engine.analysis, provider) case final target?)
          (
            classify(
              Site(path, node.offset, node.length, 'READ'),
              engine.sources,
            ),
            target,
          ),
    ],
  );
}

class _ProviderReferences extends RecursiveAstVisitor<void> {
  _ProviderReferences(this.found);

  final Map<SimpleIdentifier, Element> found;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final e = node.element;
    final variable = e is GetterElement ? e.variable : e;
    if (variable != null &&
        !node.inDeclarationContext() &&
        isProvider(variable)) {
      found[node] = variable;
    }
  }
}

class ShowFileAnswer extends Answer {
  ShowFileAnswer(
    this.outline,
    this.imports,
    this.external,
    this.importers,
    this.providers,
    this.reads,
  );

  final FileOutline outline;
  final List<(String, UriDirective)> imports;
  final List<String> external;
  final List<String> importers;
  final List<Target> providers;
  final List<ProviderRead> reads;

  @override
  String get verb => 'show';

  @override
  void write(TextOut out) {
    out.header('${outline.path}  (${outline.lines} lines)');
    out.section('outline:');
    for (final d in outline.decls) {
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
    if (providers.isNotEmpty) {
      out.section('providers declared:');
      for (final p in providers) {
        out.row('  ${p.line}: ${p.name}');
      }
    }
    if (reads.isNotEmpty) {
      out.section('provider uses:');
      for (final (use, provider) in reads) {
        out.row('  ${use.line}: ${use.role}(${provider.name})');
      }
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'file',
    'path': outline.path,
    'lines': outline.lines,
    'declarations': [for (final d in outline.decls) d.toJson()],
    'imports': [
      for (final (t, d) in imports)
        {'path': t, 'line': d.line, 'kind': d.kind.label},
    ],
    'externalImports': external,
    'importedBy': importers,
    'providers': [for (final p in providers) p.toJson()],
    'providerUses': [
      for (final (use, provider) in reads)
        {'line': use.line, 'role': use.role.label, 'provider': provider.name},
    ],
  };
}

Future<ShowFileAnswer> showFile(Engine engine, String rel) async {
  final idx = engine.outline;
  final f = idx.files[rel]!;
  final (providers, reads) = await providersIn(engine, rel);
  return ShowFileAnswer(
    f,
    idx.dependencies(rel),
    [
      for (final d in f.directives)
        if (d.kind == DirectiveKind.import &&
            idx.resolveUri(rel, d.uri) == null)
          d.uri,
    ],
    idx.importers(rel),
    providers,
    reads,
  );
}

class ShowAreaAnswer extends Answer {
  ShowAreaAnswer({
    required this.dir,
    required this.files,
    required this.pages,
    required this.providers,
    required this.importedFromOutside,
    required this.consumed,
    required this.notesPath,
    required this.notes,
  });

  final String dir;
  final int files;
  final List<(Decl, String)> pages;

  /// Each provider the area declares, with the number of files outside the
  /// area that use it.
  final List<(Target, int)> providers;

  /// Files of the area imported from outside it, with how many files do.
  final List<(String, int)> importedFromOutside;

  /// Providers declared elsewhere that the area uses, by name, to the file
  /// declaring them.
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
      out.section('providers (files outside $dir using them):');
      for (final (p, n) in providers) {
        out.row('  ${p.name}  ${p.location}  ($n)');
      }
    }
    if (importedFromOutside.isNotEmpty) {
      out.section('imported from outside $dir (importing files):');
      for (final (path, n) in importedFromOutside) {
        out.row('  $path  ($n)');
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
  Map<String, Object?> toJson() => {
    'kind': 'area',
    'path': dir,
    'files': files,
    'pages': [
      for (final (d, p) in pages) {'name': d.name, 'path': p, 'line': d.line},
    ],
    'providers': [
      for (final (p, n) in providers) {...p.toJson(), 'usedOutside': n},
    ],
    'importedFromOutside': [
      for (final (p, n) in importedFromOutside) {'path': p, 'importers': n},
    ],
    'consumed': consumed,
    'notes': ?notesPath,
  };
}

Future<ShowAreaAnswer> showArea(Engine engine, String dir) async {
  final idx = engine.outline;
  bool inside(String path) => path.startsWith('$dir/');
  final lib =
      idx.files.values
          .where(
            (f) =>
                inside(f.path) &&
                !isGeneratedFile(f.path) &&
                !isTestPath(f.path),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final declared = <Target>[];
  final consumed = SplayTreeMap<String, String>();
  for (final f in lib) {
    final (here, reads) = await providersIn(engine, f.path);
    declared.addAll(here);
    for (final (_, provider) in reads) {
      if (!inside(provider.path)) consumed[provider.name] = provider.path;
    }
  }
  final providers = await Future.wait([
    for (final p in declared)
      engine
          .usesOf(p.element)
          .then(
            (uses) => (
              p,
              {
                for (final u in uses)
                  if (!inside(u.path)) u.path,
              }.length,
            ),
          ),
  ]);
  providers.sort((a, b) => b.$2.compareTo(a.$2));

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
    importedFromOutside:
        ([
              for (final f in lib)
                (f.path, idx.importers(f.path).where((p) => !inside(p)).length),
            ].where((e) => e.$2 > 0).toList()..sort(
              (a, b) => b.$2.compareTo(a.$2),
            ))
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
