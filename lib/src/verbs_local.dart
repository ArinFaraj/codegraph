// Verbs answered from the parse-only outline index. They never need the
// worker, so they answer instantly even while the analyzer warms up.
import 'dart:collection';
import 'dart:io';

import 'outline.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

/// What an argument names. Decided once, here, for every verb that takes
/// "a file, a directory or a symbol".
sealed class Arg {}

class FileArg extends Arg {
  FileArg(this.path);
  final String path;
}

class DirArg extends Arg {
  DirArg(this.path);
  final String path;
}

class SymbolArg extends Arg {
  SymbolArg(this.query);
  final String query;
}

class ChoiceArg extends Arg {
  ChoiceArg(this.candidates);
  final List<String> candidates;
}

/// `x.dart` and anything with a `/` is a path; a bare word is a symbol, or a
/// directory when [directories] is on and `lib/<w>`, `lib/features/<w>` or
/// `packages/<w>` exists.
Arg classifyArg(OutlineIndex idx, String arg, {required bool directories}) {
  final files = fileCandidates(idx.workspace, idx.files.keys, arg);
  final dirs = directories ? _dirCandidates(idx, arg) : const <String>[];
  if (arg.endsWith('.dart')) {
    return files.length == 1 ? FileArg(files.single) : ChoiceArg(files);
  }
  if (arg.contains('/')) {
    if (dirs.length == 1) return DirArg(dirs.single);
    return files.length == 1 ? FileArg(files.single) : ChoiceArg(files);
  }
  if (dirs.length == 1) return DirArg(dirs.single);
  if (dirs.length > 1) return ChoiceArg(dirs);
  return SymbolArg(arg);
}

List<String> _dirCandidates(OutlineIndex idx, String arg) {
  final clean = arg.endsWith('/') ? arg.substring(0, arg.length - 1) : arg;
  final rel = idx.workspace.relative(idx.workspace.absolute(clean));
  bool hasFiles(String dir) => idx.files.keys.any((p) => p.startsWith('$dir/'));
  if (hasFiles(rel)) return [rel];
  if (clean.contains('/')) return const [];
  return [
    for (final dir in ['lib/$clean', 'lib/features/$clean', 'packages/$clean'])
      if (hasFiles(dir)) dir,
  ];
}

class FindHit {
  FindHit(this.decl, this.path, this.mentionedBy);
  final Decl decl;
  final String path;
  final int mentionedBy;
}

class FindAnswer extends Answer {
  FindAnswer(this.query, this.hits, this.files, this.analyzedFiles);

  final String query;
  final List<FindHit> hits;
  final List<String> files;
  final int analyzedFiles;

  @override
  String get verb => 'find';

  @override
  void write(TextOut out) {
    out.header(
      'find "$query": ${plural(hits.length, 'declaration')}'
      '${files.isEmpty ? '' : ', ${plural(files.length, 'file')}'}',
    );
    if (hits.isEmpty && files.isEmpty) {
      out.footer(
        'nothing declared or named like that in '
        '${plural(analyzedFiles, 'analyzed file')}; for string literals use rg',
      );
    }
    for (final h in hits) {
      out.row(
        '${h.decl.kind.padRight(11)} ${h.decl.qualified}  ${h.path}:${h.decl.line}'
        '  (${plural(h.mentionedBy, 'file')} mention it)',
      );
    }
    for (final p in files) {
      out.row('${'file'.padRight(11)} $p');
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'query': query,
    'declarations': [
      for (final h in hits)
        {
          'kind': h.decl.kind,
          'name': h.decl.qualified,
          'path': h.path,
          'line': h.decl.line,
          'mentionedBy': h.mentionedBy,
        },
    ],
    'files': files,
  };
}

FindAnswer find(OutlineIndex idx, String query) {
  final q = query.toLowerCase();
  final isMemberQuery = query.contains('.') && !query.endsWith('.dart');

  int tier(Decl d) {
    final k = (isMemberQuery ? d.qualified : d.name).toLowerCase();
    if (k == q) return 0;
    if (k.startsWith(q)) return 1;
    if (k.contains(q)) return 2;
    return -1;
  }

  int place(String path) => isTestPath(path)
      ? 2
      : path.startsWith('lib/') || path.contains('/lib/')
      ? 0
      : 1;

  final ranked = <(int, FindHit)>[
    for (final f in idx.files.values)
      for (final d in f.decls)
        if (!(d.kind == 'constructor' && d.name == d.owner) && tier(d) >= 0)
          (
            tier(d),
            FindHit(d, f.path, idx.mentions(d.name, exceptFile: f.path)),
          ),
  ];
  int byFlag(bool a, bool b) => (a ? 1 : 0).compareTo(b ? 1 : 0);
  ranked.sort((a, b) {
    final x = a.$2, y = b.$2;
    for (final c in [
      a.$1.compareTo(b.$1),
      byFlag(x.decl.isMember, y.decl.isMember),
      byFlag(x.decl.name != query, y.decl.name != query),
      place(x.path).compareTo(place(y.path)),
      y.mentionedBy.compareTo(x.mentionedBy),
    ]) {
      if (c != 0) return c;
    }
    return '${x.path}:${x.decl.line}'.compareTo('${y.path}:${y.decl.line}');
  });

  final files = query.length < 3
      ? <String>[]
      : (idx.files.keys.where((p) => p.toLowerCase().contains(q)).toList()
          ..sort((a, b) {
            final c = byFlag(isTestPath(a), isTestPath(b));
            return c != 0 ? c : a.compareTo(b);
          }));
  return FindAnswer(
    query,
    [for (final r in ranked) r.$2],
    files,
    idx.files.length,
  );
}

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
      out.row('  ${d.line}: $target${d.kind == 'export' ? '  (export)' : ''}');
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
      for (final (t, d) in imports) {'path': t, 'line': d.line, 'kind': d.kind},
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
      if (d.kind == 'import' && idx.resolveUri(rel, d.uri) == null) d.uri,
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
      'kind': d.kind,
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
          if (d.kind == 'class' &&
              !d.name.startsWith('_') &&
              (d.name.endsWith('Page') || d.name.endsWith('Screen')))
            (d, f.path),
    ],
    providers: providers,
    usedOutside:
        ([
                for (final f in lib)
                  for (final d in f.topLevel)
                    if (!d.name.startsWith('_') && d.kind != 'provider')
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

/// One step of an import path: the importing file, the directive kind and
/// its line, and the file it reaches.
typedef WhyStep = ({String from, String kind, int line, String to});

class WhyAnswer extends Answer {
  WhyAnswer(this.from, this.to, this.steps, {required this.reversed});

  final String from;
  final String to;

  /// Null when the files are not connected.
  final List<WhyStep>? steps;
  final bool reversed;

  @override
  String get verb => 'why';

  @override
  void write(TextOut out) {
    final s = steps;
    if (s == null) {
      out.header('$from and $to are not connected by imports or exports');
      return;
    }
    out.header(
      '${s.first.from} reaches ${s.last.to} in ${plural(s.length, 'step')}'
      '${reversed ? ' (the reverse of what you asked)' : ''}',
    );
    out.row(s.first.from);
    for (final step in s) {
      out.row('  ${step.from}:${step.line} ${step.kind}s ${step.to}');
    }
  }

  @override
  Map<String, Object?> toJson() {
    final s = steps;
    return {
      'from': from,
      'to': to,
      'reversed': reversed,
      if (s != null) 'path': [s.first.from, for (final step in s) step.to],
    };
  }
}

Answer why(OutlineIndex idx, String fromArg, String toArg) {
  final files = idx.files.keys;
  final from = fileCandidates(idx.workspace, files, fromArg);
  if (from.length != 1) return FileChoiceAnswer('why', fromArg, from);
  final to = fileCandidates(idx.workspace, files, toArg);
  if (to.length != 1) return FileChoiceAnswer('why', toArg, to);

  List<WhyStep>? search(String a, String b) {
    final prev = <String, WhyStep>{};
    final queue = Queue<String>()..add(a);
    final seen = {a};
    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      if (cur == b) break;
      for (final (next, d) in idx.dependencies(cur)) {
        if (seen.add(next)) {
          prev[next] = (from: cur, kind: d.kind, line: d.line, to: next);
          queue.add(next);
        }
      }
    }
    if (!seen.contains(b)) return null;
    final path = <WhyStep>[];
    for (var cur = b; cur != a; cur = prev[cur]!.from) {
      path.add(prev[cur]!);
    }
    return path.reversed.toList();
  }

  final forward = search(from.single, to.single);
  if (forward != null) {
    return WhyAnswer(from.single, to.single, forward, reversed: false);
  }
  final back = search(to.single, from.single);
  return WhyAnswer(from.single, to.single, back, reversed: back != null);
}
