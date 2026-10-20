// Measures how agents worked in a repository over a time window, from Claude
// Code session transcripts: the numbers the v5 plan's milestones are judged
// on. Run it on the baseline window and on the window being judged, with the
// same arguments, and compare.
//
//   dart run tool/session_audit.dart --project krdpass-app \
//       --since 2026-10-20 --until 2026-11-03 [--exclude <session id prefix>]
import 'dart:convert';
import 'dart:io';

final _grep = RegExp(r'(?:^|[;&|(]\s*|\bxargs\s+)(?:rtk\s+)?(?:rg|grep)\s');
final _analyze = RegExp(r'\b(?:dart|flutter)\s+analyze\b');
final _codegraph = RegExp(r'(?:^|[;&|(/]\s*)codegraph\s+([\w-]+)');
final _dartPath = RegExp(r'[\w./-]+\.dart\b');
final _reader = RegExp(r'\b(?:sed\s+-n|cat|head|tail)\b');
final _bashDartWrite = RegExp(
  r'sed\s+-i|perl\s+-pi|python3?\s+-\s*<<|>\s*\S+\.dart\b|write_text|'
  r'writeAsString',
);
const _readVerbs = {'find', 'show', 'refs'};
const _currentVerbs = {
  'check', 'find', 'show', 'refs', 'rename', 'doctor', 'install-native', //
  'help', '__worker',
};

class _Call {
  _Call(this.name, this.input);
  final String name;
  final Map<String, dynamic> input;
  String result = '';

  String get command => '${input['command'] ?? ''}';
}

class _Counts {
  int sessions = 0;
  int editWrites = 0;
  int bashWrites = 0;
  int analyzeRuns = 0;
  int greps = 0;
  int i18nGreps = 0;
  int codegraphReads = 0;
  int checkAll = 0;
  int renames = 0;
  int removedVerbs = 0;
  int grepLookups = 0;
  int grepLookupsRead = 0;
  int codegraphLookups = 0;
  int codegraphLookupsRead = 0;
  final hookReports = <String>[];
}

void main(List<String> argv) {
  String? option(String name) {
    final i = argv.indexOf('--$name');
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
  }

  final since = option('since');
  final until = option('until');
  if (since == null || until == null) {
    stderr.writeln(
      'usage: dart run tool/session_audit.dart --since YYYY-MM-DD '
      '--until YYYY-MM-DD [--project NAME] [--exclude SESSION_PREFIX]...',
    );
    exit(64);
  }
  final project = option('project') ?? 'krdpass-app';
  final excluded = [
    for (var i = 0; i < argv.length - 1; i++)
      if (argv[i] == '--exclude') argv[i + 1],
  ];
  final home = Platform.environment['HOME']!;
  final roots = {
    ?Platform.environment['CLAUDE_CONFIG_DIR'],
    '$home/.claude',
    '$home/.claude-work',
  };

  final counts = _Counts();
  for (final root in roots) {
    final dir = Directory('$root/projects');
    if (!dir.existsSync()) continue;
    for (final projectDir in dir.listSync().whereType<Directory>()) {
      if (!projectDir.path.contains(project)) continue;
      for (final f in projectDir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.endsWith('.jsonl') || excluded.any(name.startsWith)) {
          continue;
        }
        _session(f, since, until, counts);
      }
    }
  }
  _report(counts, since, until, project);
}

void _session(File f, String since, String until, _Counts counts) {
  final calls = <_Call>[];
  final byId = <String, _Call>{};
  var inWindow = false;
  for (final line in f.readAsLinesSync()) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final ts = j['timestamp'] as String? ?? '';
    if (ts.compareTo(since) < 0 || ts.compareTo(until) >= 0) continue;
    inWindow = true;
    if (j['attachment'] case {
      'type': 'hook_blocking_error',
      'hookName': final String hook,
      'blockingError': final String error,
    } when hook.startsWith('PostToolUse') && error.contains('check:')) {
      if (!error.toLowerCase().contains('cgprobe') &&
          !error.contains('cg_probe')) {
        final at = error.indexOf('check:');
        counts.hookReports.add(
          '${ts.substring(0, 16)}  ${error.substring(at).split('\n').first}',
        );
      }
    }
    final content = (j['message'] as Map?)?['content'];
    if (content is! List) continue;
    for (final block in content.whereType<Map>()) {
      switch (block['type']) {
        case 'tool_use':
          final call = _Call(
            '${block['name']}',
            (block['input'] as Map?)?.cast<String, dynamic>() ?? const {},
          );
          calls.add(call);
          byId['${block['id']}'] = call;
        case 'tool_result':
          final call = byId['${block['tool_use_id']}'];
          if (call != null) call.result = _text(block['content']);
      }
    }
  }
  if (!inWindow) return;
  counts.sessions++;

  for (var i = 0; i < calls.length; i++) {
    final c = calls[i];
    if (c.name == 'Grep') counts.greps++;
    if ({'Edit', 'Write', 'MultiEdit'}.contains(c.name) &&
        '${c.input['file_path']}'.endsWith('.dart')) {
      counts.editWrites++;
    }
    if (c.name != 'Bash') continue;
    final cmd = c.command;
    final verbs = [for (final m in _codegraph.allMatches(cmd)) m.group(1)!];
    if (cmd.contains('.dart') &&
        _bashDartWrite.hasMatch(cmd) &&
        !cmd.contains('dart format')) {
      counts.bashWrites++;
    }
    if (_analyze.hasMatch(cmd)) counts.analyzeRuns++;
    if (verbs.contains('check') && cmd.contains('--all')) counts.checkAll++;
    if (verbs.contains('rename')) counts.renames++;
    counts.removedVerbs += verbs
        .where((v) => !_currentVerbs.contains(v))
        .length;
    final isGrep = _grep.hasMatch(cmd);
    final isRead = verbs.any(_readVerbs.contains);
    if (isGrep) {
      counts.greps++;
      if (cmd.contains('i18n/yaml')) counts.i18nGreps++;
    }
    if (isRead) counts.codegraphReads++;
    if (!isGrep && !isRead) continue;

    final printed = {
      for (final m in _dartPath.allMatches(c.result)) m.group(0)!,
    };
    if (printed.isEmpty) continue;
    final read = _readsOneOf(calls.skip(i + 1).take(2), printed);
    if (isRead) {
      counts.codegraphLookups++;
      if (read) counts.codegraphLookupsRead++;
    } else {
      counts.grepLookups++;
      if (read) counts.grepLookupsRead++;
    }
  }
}

bool _readsOneOf(Iterable<_Call> next, Set<String> paths) {
  bool names(String s) => paths.any((p) => s.endsWith(p) || s.contains(p));
  for (final c in next) {
    if (c.name == 'Read' && names('${c.input['file_path']}')) return true;
    if (c.name == 'Bash' && _reader.hasMatch(c.command) && names(c.command)) {
      return true;
    }
  }
  return false;
}

String _text(Object? content) => switch (content) {
  final String s => s,
  final List<Object?> parts => [
    for (final p in parts)
      if (p is Map && p['text'] is String) p['text'] as String,
  ].join('\n'),
  _ => '',
};

void _report(_Counts c, String since, String until, String project) {
  final days =
      DateTime.parse(until).difference(DateTime.parse(since)).inHours / 24;
  String rate(int part, int whole) =>
      whole == 0 ? '-' : '${(100 * part / whole).toStringAsFixed(1)}%';
  String perDay(int n) => (n / days).toStringAsFixed(1);
  final rows = [
    ('sessions', c.sessions),
    ('Dart writes via Edit/Write', c.editWrites),
    ('Bash commands writing .dart', c.bashWrites),
    ('dart/flutter analyze runs', c.analyzeRuns),
    ('codegraph check --all runs', c.checkAll),
    ('greps (rg, grep, Grep)', c.greps),
    ('greps over i18n/yaml', c.i18nGreps),
    ('codegraph find/show/refs', c.codegraphReads),
    ('codegraph rename', c.renames),
    ('removed codegraph verbs', c.removedVerbs),
    ('hook reports (probes excluded)', c.hookReports.length),
  ];
  stdout.writeln(
    '$project, $since to $until (${days.toStringAsFixed(1)} days)',
  );
  for (final (label, n) in rows) {
    stdout.writeln(
      '${label.padRight(34)}${'$n'.padLeft(7)}'
      '${perDay(n).padLeft(9)}/day',
    );
  }
  stdout.writeln(
    'greps per codegraph read verb       '
    '${c.codegraphReads == 0 ? '-' : (c.greps / c.codegraphReads).toStringAsFixed(1)}',
  );
  stdout.writeln(
    'lookups followed by a read of a hit: grep '
    '${rate(c.grepLookupsRead, c.grepLookups)} of ${c.grepLookups}, '
    'codegraph ${rate(c.codegraphLookupsRead, c.codegraphLookups)} of '
    '${c.codegraphLookups}',
  );
  for (final r in c.hookReports) {
    stdout.writeln('  $r');
  }
}
