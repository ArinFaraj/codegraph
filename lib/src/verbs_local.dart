// Verbs answered from the parse-only outline index. They never need the
// worker, so they answer instantly even while the analyzer warms up.
import 'dart:collection';
import 'dart:io';

import 'outline.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

Result find(OutlineIndex idx, String query) {
  final r = Result('find')..json['query'] = query;
  final q = query.toLowerCase();
  final isMemberQuery = query.contains('.') && !query.endsWith('.dart');

  int tier(Decl d) {
    final key = isMemberQuery ? d.qualified : d.name;
    final k = key.toLowerCase();
    if (k == q) return 0;
    if (k.startsWith(q)) return 1;
    if (k.contains(q)) return 2;
    return -1;
  }

  final hits = <(int, int, Decl, String)>[];
  for (final f in idx.files.values) {
    for (final d in f.decls) {
      if (d.kind == 'constructor' && d.name == d.owner) continue;
      final t = tier(d);
      if (t < 0) continue;
      hits.add((t, 0, d, f.path));
    }
  }
  int place(String path) => isTestPath(path)
      ? 2
      : path.startsWith('lib/') || path.contains('/lib/')
      ? 0
      : 1;
  final ranked =
      [
        for (final (t, _, d, path) in hits)
          (t, idx.mentions(d.name, exceptFile: path), d, path),
      ]..sort((a, b) {
        var c = a.$1.compareTo(b.$1);
        if (c != 0) return c;
        c = (a.$3.isMember ? 1 : 0).compareTo(b.$3.isMember ? 1 : 0);
        if (c != 0) return c;
        c = (a.$3.name == query ? 0 : 1).compareTo(b.$3.name == query ? 0 : 1);
        if (c != 0) return c;
        c = place(a.$4).compareTo(place(b.$4));
        if (c != 0) return c;
        c = b.$2.compareTo(a.$2);
        if (c != 0) return c;
        return '${a.$4}:${a.$3.line}'.compareTo('${b.$4}:${b.$3.line}');
      });

  final fileHits = query.length < 3
      ? <String>[]
      : (idx.files.keys.where((p) => p.toLowerCase().contains(q)).toList()
          ..sort((a, b) {
            final c = (isTestPath(a) ? 1 : 0).compareTo(isTestPath(b) ? 1 : 0);
            return c != 0 ? c : a.compareTo(b);
          }));

  r.header(
    'find "$query": ${plural(ranked.length, 'declaration')}'
    '${fileHits.isEmpty ? '' : ', ${plural(fileHits.length, 'file')}'}',
  );
  if (ranked.isEmpty && fileHits.isEmpty) {
    r.footer(
      'nothing declared or named like that in '
      '${plural(idx.files.length, 'analyzed file')}; '
      'for string literals use rg',
    );
  }
  for (final (_, mentions, d, path) in ranked) {
    r.row(
      '${d.kind.padRight(11)} ${d.qualified}  $path:${d.line}'
      '  (${plural(mentions, 'file')} mention it)',
    );
  }
  for (final p in fileHits) {
    r.row('${'file'.padRight(11)} $p');
  }
  r.json['declarations'] = [
    for (final (_, mentions, d, path) in ranked)
      {
        'kind': d.kind,
        'name': d.qualified,
        'path': path,
        'line': d.line,
        'mentionedBy': mentions,
      },
  ];
  r.json['files'] = fileHits;
  return r;
}

Result showFile(OutlineIndex idx, String rel) {
  final f = idx.files[rel]!;
  final r = Result('show')
    ..json['kind'] = 'file'
    ..json['path'] = rel
    ..json['lines'] = f.lines;
  r.header('$rel  (${f.lines} lines)');
  r.section('outline:');
  for (final d in f.decls) {
    if (d.kind == 'provider' && d.sig.contains('@riverpod')) continue;
    r.row('${d.isMember ? '    ' : '  '}${d.line}: ${d.sig}');
  }
  final deps = idx.dependencies(rel);
  final external = f.directives
      .where((d) => d.kind == 'import' && idx.resolveUri(rel, d.uri) == null)
      .map((d) => d.uri)
      .toList();
  r.section(
    'imports (${deps.length} in workspace, ${external.length} external):',
  );
  for (final (target, d) in deps) {
    r.row('  ${d.line}: $target${d.kind == 'export' ? '  (export)' : ''}');
  }
  final importers = idx.importers(rel);
  r.section('imported by (${importers.length}):');
  for (final p in importers) {
    r.row('  $p');
  }
  final providers = f.providers.toList();
  if (providers.isNotEmpty) {
    r.section('providers declared:');
    for (final p in providers) {
      r.row('  ${p.line}: ${p.sig}');
    }
  }
  if (f.providerUses.isNotEmpty) {
    r.section('provider uses:');
    for (final u in f.providerUses) {
      r.row('  ${u.line}: ${u.role}(${u.provider})');
    }
  }
  r.json['declarations'] = [for (final d in f.decls) d.toJson()];
  r.json['imports'] = [
    for (final (t, d) in deps) {'path': t, 'line': d.line, 'kind': d.kind},
  ];
  r.json['externalImports'] = external;
  r.json['importedBy'] = importers;
  r.json['providerUses'] = [for (final u in f.providerUses) u.toJson()];
  return r;
}

/// Directories that can be summarized as an area for [arg].
List<String> areaCandidates(OutlineIndex idx, String arg) {
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

Result showArea(OutlineIndex idx, String dir) {
  final r = Result('show')
    ..json['kind'] = 'area'
    ..json['path'] = dir;
  final inArea =
      idx.files.values
          .where((f) => f.path.startsWith('$dir/') && !isGeneratedFile(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final lib = inArea.where((f) => !isTestPath(f.path)).toList();
  final providers = [
    for (final f in lib)
      for (final p in f.providers) (p, f.path),
  ];
  r.header(
    '$dir  (${plural(lib.length, 'file')}, '
    '${plural(providers.length, 'provider')})',
  );

  final pages = [
    for (final f in lib)
      for (final d in f.topLevel)
        if (d.kind == 'class' &&
            !d.name.startsWith('_') &&
            (d.name.endsWith('Page') || d.name.endsWith('Screen')))
          (d, f.path),
  ];
  if (pages.isNotEmpty) {
    r.section('pages:');
    for (final (d, path) in pages) {
      r.row('  ${d.name}  $path:${d.line}');
    }
  }

  int outside(String name) {
    var n = 0;
    for (final f in idx.files.values) {
      if (!f.path.startsWith('$dir/') && f.identifiers.contains(name)) n++;
    }
    return n;
  }

  if (providers.isNotEmpty) {
    final ranked = [
      for (final (p, path) in providers)
        (p, path, idx.mentions(p.name, exceptFile: path)),
    ]..sort((a, b) => b.$3.compareTo(a.$3));
    r.section('providers (by files mentioning them):');
    for (final (p, path, n) in ranked) {
      r.row('  ${p.name}  $path:${p.line}  ($n)');
    }
  }

  final symbols = [
    for (final f in lib)
      for (final d in f.topLevel)
        if (!d.name.startsWith('_') && d.kind != 'provider')
          (d, f.path, outside(d.name)),
  ]..sort((a, b) => b.$3.compareTo(a.$3));
  final used = symbols.where((s) => s.$3 > 0).take(15).toList();
  if (used.isNotEmpty) {
    r.section('most used outside $dir (files mentioning them):');
    for (final (d, path, n) in used) {
      r.row('  ${d.kind} ${d.name}  $path:${d.line}  ($n)');
    }
  }

  final declaredHere = {for (final (p, _) in providers) p.name};
  final providerHome = <String, String>{
    for (final f in idx.files.values)
      for (final p in f.providers) p.name: f.path,
  };
  final consumed = SplayTreeMap<String, String>();
  for (final f in lib) {
    for (final u in f.providerUses) {
      if (declaredHere.contains(u.provider)) continue;
      final home = providerHome[u.provider];
      if (home != null) consumed[u.provider] = home;
    }
  }
  if (consumed.isNotEmpty) {
    r.section('providers used from other areas:');
    for (final e in consumed.entries) {
      r.row('  ${e.key}  ${e.value}');
    }
  }

  final notes = _notesFor(idx.workspace, dir);
  if (notes != null) {
    final lines = File(notes).readAsLinesSync();
    r.footer(
      'notes (${idx.workspace.relative(notes)}, ${lines.length} lines):',
    );
    for (final l in lines.take(40)) {
      r.footer('  $l');
    }
    if (lines.length > 40) r.footer('  ... read the file for the rest');
    r.json['notes'] = idx.workspace.relative(notes);
  }
  r.json['files'] = lib.length;
  r.json['providers'] = [
    for (final (p, path) in providers)
      {'name': p.name, 'path': path, 'line': p.line},
  ];
  r.json['consumed'] = consumed;
  return r;
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

Result why(OutlineIndex idx, String fromArg, String toArg) {
  final r = Result('why');
  final from = resolveFile(idx, fromArg);
  final to = resolveFile(idx, toArg);
  for (final (arg, value) in [(fromArg, from), (toArg, to)]) {
    if (value == null) {
      final c = fileCandidates(idx, arg);
      r.exit = c.isEmpty ? Exit.failed : Exit.ambiguous;
      r.header(
        c.isEmpty
            ? 'no analyzed file matches "$arg"'
            : '"$arg" matches ${plural(c.length, 'file')}:',
      );
      for (final p in c.take(20)) {
        r.row('  $p');
      }
      return r;
    }
  }
  List<(String, String, int)>? search(String a, String b) {
    final prev = <String, (String, String, int)>{};
    final queue = Queue<String>()..add(a);
    final seen = {a};
    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      if (cur == b) break;
      for (final (next, d) in idx.dependencies(cur)) {
        if (seen.add(next)) {
          prev[next] = (cur, d.kind, d.line);
          queue.add(next);
        }
      }
    }
    if (!seen.contains(b)) return null;
    final path = <(String, String, int)>[];
    var cur = b;
    while (cur != a) {
      final (p, kind, line) = prev[cur]!;
      path.add((p, kind, line));
      cur = p;
    }
    return path.reversed.toList();
  }

  var chain = search(from!, to!);
  var reversed = false;
  if (chain == null) {
    chain = search(to, from);
    reversed = chain != null;
  }
  if (chain == null) {
    r.header('$from and $to are not connected by imports or exports');
    return r;
  }
  final start = reversed ? to : from;
  final end = reversed ? from : to;
  r.header(
    '$start reaches $end in ${plural(chain.length, 'step')}'
    '${reversed ? ' (the reverse of what you asked)' : ''}',
  );
  r.row(start);
  for (var i = 0; i < chain.length; i++) {
    final (file, kind, line) = chain[i];
    final next = i + 1 < chain.length ? chain[i + 1].$1 : end;
    r.row('  $file:$line ${kind}s $next');
  }
  r.json['path'] = [
    start,
    for (var i = 1; i < chain.length; i++) chain[i].$1,
    end,
  ];
  return r;
}
