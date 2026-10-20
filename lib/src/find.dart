// `find`: declarations by name, from the parse-only outline.
import 'kinds.dart';
import 'outline.dart';
import 'result.dart';
import 'workspace.dart';

class FindHit {
  FindHit(this.decl, this.path);
  final Decl decl;
  final String path;
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
        '${h.decl.kind.label.padRight(11)} ${h.decl.qualified}  '
        '${h.path}:${h.decl.line}',
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
          'kind': h.decl.kind.label,
          'name': h.decl.qualified,
          'path': h.path,
          'line': h.decl.line,
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
        if (!isUnnamedConstructor(d.kind, d.name, d.owner) && tier(d) >= 0)
          (tier(d), FindHit(d, f.path)),
  ];
  int byFlag(bool a, bool b) => (a ? 1 : 0).compareTo(b ? 1 : 0);
  ranked.sort((a, b) {
    final x = a.$2, y = b.$2;
    for (final c in [
      a.$1.compareTo(b.$1),
      byFlag(x.decl.isMember, y.decl.isMember),
      byFlag(x.decl.name != query, y.decl.name != query),
      place(x.path).compareTo(place(y.path)),
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
