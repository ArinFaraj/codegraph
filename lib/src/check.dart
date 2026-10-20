// `check`: what a change broke. The worker keeps a ledger of the problems
// every file had when it last looked; a check reports only problems that are
// new against it, in the files a change wrote and everything depending on
// them. Problems in files outside that reach stay unacknowledged, so the
// agent whose write reaches them is the one told.
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'classify.dart';
import 'engine.dart';
import 'request.dart';
import 'result.dart';
import 'workspace.dart';

/// Problems per file, by identity, as last reported or acknowledged.
class Ledger {
  Ledger._(this._seen);

  final Map<String, Map<String, int>> _seen;

  /// Changed since it was last saved.
  bool _dirty = false;

  /// A saved ledger is trusted this long, and only on the commit it was
  /// saved at: after a branch switch its "known" problems belong to other
  /// files.
  static const maxAge = Duration(hours: 24);

  static String pathFor(Workspace ws) => '${ws.stateDir}/ledger.json';

  /// The ledger the last worker saved, when it is recent and on this commit.
  static Ledger? load(Workspace ws) {
    try {
      final j =
          jsonDecode(File(pathFor(ws)).readAsStringSync())
              as Map<String, dynamic>;
      final saved = DateTime.parse(j['saved'] as String);
      if (j['v'] != 1 ||
          j['head'] != gitHead(ws) ||
          DateTime.now().difference(saved) > maxAge) {
        return null;
      }
      return Ledger._({
        for (final e in (j['seen'] as Map<String, dynamic>).entries)
          e.key: (e.value as Map<String, dynamic>).cast<String, int>(),
      });
    } catch (_) {
      return null;
    }
  }

  /// Writes the ledger for the next worker, when it changed.
  void save(Workspace ws) {
    if (!_dirty) return;
    final file = File(pathFor(ws));
    try {
      file.parent.createSync(recursive: true);
      File('${file.path}.$pid.tmp')
        ..writeAsStringSync(
          jsonEncode({
            'v': 1,
            'head': gitHead(ws),
            'saved': DateTime.now().toIso8601String(),
            'seen': {
              for (final e in _seen.entries)
                if (e.value.isNotEmpty) e.key: e.value,
            },
          }),
        )
        ..renameSync(file.path);
      _dirty = false;
    } on FileSystemException {
      return;
    }
  }

  static Future<Ledger> build(Engine engine) async {
    final seen = <String, Map<String, int>>{};
    for (final (path, problems) in await problemsOf(
      engine,
      checkedFiles(engine),
    )) {
      seen[path] = _counts(problems);
    }
    return Ledger._(seen).._dirty = true;
  }

  /// Problems in [now] beyond what the ledger holds for [path]; records
  /// [now] as seen.
  List<Problem> acknowledge(String path, List<Problem> now) {
    final before = _seen[path] ?? const {};
    final counts = _counts(now);
    if (!_sameCounts(before, counts)) _dirty = true;
    _seen[path] = counts;
    final budget = {...before};
    final out = <Problem>[];
    for (final p in now) {
      final left = budget[p.identity] ?? 0;
      if (left > 0) {
        budget[p.identity] = left - 1;
      } else {
        out.add(p);
      }
    }
    return out;
  }

  static bool _sameCounts(Map<String, int> a, Map<String, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static Map<String, int> _counts(List<Problem> problems) {
    final out = <String, int>{};
    for (final p in problems) {
      out[p.identity] = (out[p.identity] ?? 0) + 1;
    }
    return out;
  }
}

/// Every analyzed Dart file plus the pubspecs `dart analyze` validates.
List<String> checkedFiles(Engine engine) => [
  ...engine.analysis.files,
  ...pubspecs(engine),
];

/// The `pubspec.yaml` of the workspace and of every path package with
/// analyzed files.
List<String> pubspecs(Engine engine) {
  final ws = engine.workspace;
  final files = engine.analysis.files.toList();
  return [
    for (final root in ws.packageRoots().values)
      if (ws.relativeOrNull(root) case final rel?)
        if (rel == '.' || files.any((f) => f.startsWith('$rel/')))
          rel == '.' ? 'pubspec.yaml' : '$rel/pubspec.yaml',
  ]..sort();
}

Future<List<(String, List<Problem>)>> problemsOf(
  Engine engine,
  Iterable<String> paths,
) => Future.wait([
  for (final p in paths)
    (p.endsWith('pubspec.yaml')
            ? Future.value(engine.analysis.pubspecProblems(p))
            : engine.analysis.problems(p))
        .then((problems) => (p, problems)),
]);

Future<Answer> check(
  Engine engine, {
  List<String> paths = const [],
  DateTime? since,
  bool all = false,
}) async {
  if (all) {
    final found = await problemsOf(engine, checkedFiles(engine));
    return AllProblemsAnswer(
      [for (final (_, ps) in found) ...ps],
      found.length,
      engine.sources,
      engine.workspace.analyzerPlugins(),
    );
  }
  final ledger = engine.ledger;
  if (ledger == null) return NotReadyAnswer();

  final ws = engine.workspace;
  final written = <String>{
    for (final p in paths)
      if (ws.relativeOrNull(_realPath(p)) case final rel?) rel,
    if (since != null) ...engine.analysis.modifiedSince(since),
  };
  final removed = since == null
      ? const <String>[]
      : engine.lastDelta?.removed ?? const [];
  final List<String> scope;
  if (paths.isEmpty && since == null) {
    scope = checkedFiles(engine);
  } else {
    final yamls = written.where((p) => p.endsWith('pubspec.yaml')).toList();
    scope = [
      ...engine.outline.affectedBy(written, removed: removed),
      for (final y in yamls)
        if (pubspecs(engine).contains(y)) y,
      for (final y in yamls)
        ...engine.analysis.files.where(
          (f) => y == 'pubspec.yaml' || f.startsWith(_dirOf(y)),
        ),
    ];
  }
  final found = <Problem>[];
  for (final (path, problems) in await problemsOf(engine, scope.toSet())) {
    found.addAll(ledger.acknowledge(path, problems));
  }
  ledger.save(ws);
  return CheckAnswer(
    written: [...written, ...removed]..sort(),
    checked: scope.toSet().length,
    problems: found,
    sources: engine.sources,
  );
}

/// The commit checked out in [ws], or null outside git.
String? gitHead(Workspace ws) {
  try {
    final r = Process.runSync('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: ws.root);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

String _lineText(SourceCache sources, String path, int line) {
  try {
    final lines = sources.text(path).split('\n');
    return line >= 1 && line <= lines.length ? lines[line - 1].trim() : '';
  } on FileSystemException {
    return '';
  }
}

/// [path] with symlinks resolved, as the workspace root is; a deleted file
/// resolves through its directory.
String _realPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    final file = File(path);
    try {
      return '${file.parent.resolveSymbolicLinksSync()}/'
          '${file.uri.pathSegments.last}';
    } on FileSystemException {
      return path;
    }
  }
}

String _dirOf(String rel) => rel.substring(0, rel.lastIndexOf('/') + 1);

void _writeProblems(TextOut out, List<Problem> problems, SourceCache sources) {
  final sorted = [...problems]
    ..sort((a, b) {
      final c = a.path.compareTo(b.path);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });
  for (final p in sorted) {
    out.row(
      '${p.path}:${p.line}:${p.column}  ${p.severity}  ${p.code}  ${p.message}',
    );
    final line = _lineText(sources, p.path, p.line);
    if (line.isNotEmpty) out.row('    $line');
  }
}

class CheckAnswer extends Answer {
  CheckAnswer({
    required this.written,
    required this.checked,
    required this.problems,
    required this.sources,
  });

  final List<String> written;
  final int checked;
  final List<Problem> problems;
  final SourceCache sources;

  @override
  String get verb => 'check';

  @override
  int get exit => problems.isEmpty ? Exit.ok : Exit.failed;

  @override
  void write(TextOut out) {
    final from = written.isEmpty
        ? ''
        : written.length == 1
        ? ' from ${written.single}'
        : ' from ${plural(written.length, 'changed file')}';
    if (problems.isEmpty) {
      out.header('check: no new problems in ${plural(checked, 'file')}$from');
      return;
    }
    out.header(
      'check: ${plural(problems.length, 'new problem')}$from '
      '(${plural(checked, 'file')} checked)',
    );
    _writeProblems(out, problems, sources);
  }

  @override
  Map<String, Object?> toJson() => {
    'written': written,
    'checked': checked,
    'problems': [for (final p in problems) p.toJson()],
  };
}

class AllProblemsAnswer extends Answer {
  AllProblemsAnswer(this.problems, this.checked, this.sources, this.plugins);

  final List<Problem> problems;
  final int checked;
  final SourceCache sources;

  /// Analyzer plugins the workspace enables, which `check` does not run.
  final List<String> plugins;

  @override
  String get verb => 'check';

  @override
  int get exit => problems.isEmpty ? Exit.ok : Exit.failed;

  @override
  void write(TextOut out) {
    out.header(
      problems.isEmpty
          ? 'check --all: no problems in ${plural(checked, 'file')}'
          : 'check --all: ${plural(problems.length, 'problem')} in '
                '${plural(checked, 'file')}',
    );
    _writeProblems(out, problems, sources);
    if (plugins.isNotEmpty) {
      out.footer(
        'not run here: analyzer plugins ${plugins.join(', ')}; '
        'dart analyze runs them',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'checked': checked,
    'problems': [for (final p in problems) p.toJson()],
    'pluginsNotRun': plugins,
  };
}

class NotReadyAnswer extends Answer {
  @override
  String get verb => 'check';

  @override
  void write(TextOut out) => out.header(
    'check: the analyzer is still warming up, so there is nothing to compare '
    'against yet; run check --all for every current problem',
  );

  @override
  Map<String, Object?> toJson() => {'ready': false};
}

class CheckRequest extends WorkerRequest {
  CheckRequest({
    this.paths = const [],
    this.since,
    this.all = false,
    required super.json,
    required super.limit,
  });

  CheckRequest.fromJson(Map<String, dynamic> j)
    : this(
        paths: (j['paths'] as List).cast<String>(),
        since: j['since'] == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(j['since'] as int),
        all: j['all'] as bool,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  final List<String> paths;
  final DateTime? since;
  final bool all;

  @override
  String get verb => 'check';

  @override
  Map<String, Object?> get fields => {
    'paths': paths,
    'since': since?.microsecondsSinceEpoch,
    'all': all,
  };

  @override
  Future<Answer> run(Engine engine) =>
      check(engine, paths: paths, since: since, all: all);
}
