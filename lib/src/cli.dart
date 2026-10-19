import 'dart:io';

import 'analysis.dart' show analyzerLanguageVersion;
import 'client.dart';
import 'engine.dart';
import 'native_install.dart' as native_install;
import 'outline.dart';
import 'registry.dart';
import 'rename.dart' as rename_verb;
import 'result.dart';
import 'sdk.dart';
import 'symbols.dart';
import 'verbs_local.dart';
import 'version.dart';
import 'worker.dart';
import 'workspace.dart';

const help =
    '''
codegraph $codegraphVersion - exact answers about a Dart or Flutter repository

  codegraph find <name>               where something is declared (instant)
  codegraph show <file|dir|symbol>    outline of a file, digest of a directory,
                                      or a symbol: signature, subtypes,
                                      overrides, use counts; providers list
                                      their readers by role
  codegraph refs <symbol>             every use, path:line, grouped by role
                                      (ref.watch, call, implement, ...)
  codegraph impact <symbol|file>      what uses it, one step further, and the
  codegraph impact --diff [--base R]  tests that reach it; --diff seeds from
                                      the working tree or the branch since R
  codegraph rename <symbol> <new>     dry run of a complete rename; --apply
                                      writes it, re-analyzes the affected
                                      files, and rolls back on new errors
  codegraph why <fileA> <fileB>       the import path from one file to another
  codegraph doctor [--warm|--stop|--restart]
                                      worker and setup status

symbols: Name, Owner.member, path/to/file.dart:name, path/to/file.dart:LINE
flags:   --json, --limit N (default 40 rows), --all

refs, impact, rename and show <symbol> are answered by a background worker
that keeps the Dart analyzer warm for this checkout and exits after 20 idle
minutes. Its answers cover every file `dart analyze` sees, as it is on disk
now. Exit codes: 0 answered, 1 not found or failed, 2 ambiguous (candidates
listed), 3 rename refused or rolled back, 64 usage, 66 cannot analyze.''';

const _removed = {
  'brief': 'show <thing>',
  'sym': 'show <symbol>',
  'skeleton': 'show <file>',
  'wiring': 'show <file>',
  'uses': 'refs <symbol>',
  'readers': 'refs <provider> or show <provider>',
  'provider': 'show <provider>',
  'callers': 'refs <symbol>',
  'impls': 'show <type> (subtypes are listed)',
  'path': 'why <fileA> <fileB>',
  'change': 'impact <symbol|file>',
  'review': 'impact --diff --base <ref>',
  'diff': 'impact --diff --base <ref>',
  'affected-tests':
      'impact --diff (tests section), or the repository\'s own test selector',
  'lint': 'nothing: architecture rules belong in the repository\'s tests',
  'build': 'nothing: there is nothing to build; answers are computed on demand',
  'check': 'nothing: no generated files exist to check',
  'daemon': 'doctor --warm / --stop',
  'init': 'nothing: no scaffolding is installed',
  'upgrade': 'nothing: no scaffolding is installed',
  'passport': 'show <dir>',
  'attention': 'nothing',
  'health': 'nothing',
  'unused': 'refs <symbol> (0 uses means unused)',
  'untested': 'impact <symbol> (tests section)',
  'plan': 'show <dir>',
  'blueprint': 'show <dir>',
  'trace': 'find <name> for each frame',
  'route': 'show <RouteData class>',
  'callchain': 'refs <symbol>',
};

class Command {
  Command(
    this.verb,
    this.args, {
    this.json = false,
    this.limit = 40,
    this.apply = false,
    this.diff = false,
    this.base,
    this.warm = false,
    this.stop = false,
    this.restart = false,
    this.help = false,
    this.error,
  });

  factory Command.parse(List<String> argv) {
    var verb = '';
    final args = <String>[];
    var json = false;
    int? limit = 40;
    var apply = false;
    var diff = false;
    String? base;
    var warm = false;
    var stop = false;
    var restart = false;
    var helpFlag = false;
    String? error;
    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      switch (a) {
        case '--json':
          json = true;
        case '--all':
          limit = null;
        case '--apply':
          apply = true;
        case '--diff':
          diff = true;
        case '--warm':
          warm = true;
        case '--stop':
          stop = true;
        case '--restart':
          restart = true;
        case '--help' || '-h':
          helpFlag = true;
        case '--limit':
          final n = i + 1 < argv.length ? int.tryParse(argv[i + 1]) : null;
          if (n == null || n < 1) {
            error = '--limit needs a positive number';
          } else {
            limit = n;
            i++;
          }
        case '--base':
          if (i + 1 >= argv.length) {
            error = '--base needs a git ref';
          } else {
            base = argv[++i];
            diff = true;
          }
        default:
          if (a.startsWith('--')) {
            error = 'unknown flag $a';
          } else if (verb.isEmpty) {
            verb = a;
          } else {
            args.add(a);
          }
      }
    }
    return Command(
      verb,
      args,
      json: json,
      limit: limit,
      apply: apply,
      diff: diff,
      base: base,
      warm: warm,
      stop: stop,
      restart: restart,
      help: helpFlag,
      error: error,
    );
  }

  final String verb;
  final List<String> args;
  final bool json;
  final int? limit;
  final bool apply;
  final bool diff;
  final String? base;
  final bool warm;
  final bool stop;
  final bool restart;
  final bool help;
  final String? error;
}

/// Verbs that need resolved analysis, run inside the worker.
Future<Result> runResolvedVerb(Engine engine, Command c) async {
  switch (c.verb) {
    case 'refs':
      return engine.refs(c.args.single);
    case 'show':
      return engine.showSymbol(c.args.single);
    case 'impact':
      return engine.impact(
        c.args.isEmpty ? '' : c.args.single,
        diff: c.diff,
        base: c.base,
      );
    case 'rename':
      return rename_verb.rename(engine, c.args[0], c.args[1], apply: c.apply);
  }
  return Result(c.verb, exit: Exit.usage)..header('unknown verb ${c.verb}');
}

Future<int> runCli(List<String> argv) async {
  if (argv.isNotEmpty && argv.first == '__worker') {
    return runWorker(argv.length > 1 ? argv[1] : Directory.current.path);
  }
  if (argv.contains('--version')) {
    stdout.writeln('codegraph $codegraphVersion');
    return 0;
  }
  if (argv.isEmpty || argv.first == 'help') {
    stdout.writeln(help);
    return 0;
  }
  if (argv.first == 'install-native')
    return native_install.run(argv.skip(1).toList());

  final c = Command.parse(argv);
  if (c.help) {
    stdout.writeln(help);
    return 0;
  }
  if (c.error != null) return _usage(c.error!);
  if (_removed[c.verb] case final replacement?) {
    stderr.writeln(
      'codegraph 4 has no "${c.verb}". Use: codegraph $replacement',
    );
    return Exit.usage;
  }

  final ws = Workspace.find();
  if (ws == null) {
    stderr.writeln(
      'no pubspec.yaml here or above; run codegraph inside a Dart '
      'or Flutter package',
    );
    return Exit.cannotAnalyze;
  }

  switch (c.verb) {
    case 'find':
      if (c.args.length != 1) return _usage('codegraph find <name>');
      return _print(find(OutlineIndex.load(ws), c.args.single), c);
    case 'why':
      if (c.args.length != 2) return _usage('codegraph why <fileA> <fileB>');
      return _print(why(OutlineIndex.load(ws), c.args[0], c.args[1]), c);
    case 'show':
      if (c.args.length != 1) return _usage('codegraph show <file|dir|symbol>');
      final local = _localShow(ws, c.args.single);
      if (local != null) return _print(local, c);
      return _resolved(ws, c, argv);
    case 'refs':
      if (c.args.length != 1) return _usage('codegraph refs <symbol>');
      return _resolved(ws, c, argv);
    case 'impact':
      if (c.args.length != (c.diff ? 0 : 1)) {
        return _usage(
          'codegraph impact <symbol|file>, or impact --diff [--base <ref>]',
        );
      }
      return _resolved(ws, c, argv);
    case 'rename':
      if (c.args.length != 2)
        return _usage('codegraph rename <symbol> <newName> [--apply]');
      return _resolved(ws, c, argv);
    case 'doctor':
      return _doctor(ws, c);
  }
  return _usage('unknown verb "${c.verb}"; run codegraph help');
}

Result? _localShow(Workspace ws, String arg) {
  final idx = OutlineIndex.load(ws);
  final looksLikePath = arg.contains('/') || arg.endsWith('.dart');
  final files = fileCandidates(idx, arg);
  if (arg.endsWith('.dart') ||
      (looksLikePath && files.length == 1 && files.single == arg)) {
    if (files.length == 1) return showFile(idx, files.single);
    final r = Result(
      'show',
      exit: files.isEmpty ? Exit.failed : Exit.ambiguous,
    );
    r.header(
      files.isEmpty
          ? 'no analyzed file matches "$arg"'
          : '"$arg" matches ${plural(files.length, 'file')}:',
    );
    for (final p in files) {
      r.row('  $p');
    }
    return r;
  }
  final areas = areaCandidates(idx, arg);
  if (areas.length == 1) return showArea(idx, areas.single);
  if (areas.length > 1) {
    final r = Result('show', exit: Exit.ambiguous)
      ..header(
        '"$arg" matches ${plural(areas.length, 'directory', 'directories')}:',
      );
    for (final a in areas) {
      r.row('  $a');
    }
    return r;
  }
  if (looksLikePath && files.length == 1) return showFile(idx, files.single);
  return null;
}

Future<int> _resolved(Workspace ws, Command c, List<String> argv) async {
  final reason = ws.unresolvableReason;
  if (reason != null) {
    stderr.writeln(reason);
    return Exit.cannotAnalyze;
  }
  final state = await ensureWorker(ws);
  if (state == null) {
    stderr.writeln(
      'could not start the codegraph worker; see '
      '${ws.relative(WorkerState.logPath(ws))}',
    );
    return Exit.failed;
  }
  var lastProgress = DateTime(0);
  final response = await sendToWorker(
    state,
    {'type': 'run', 'argv': argv},
    onProgress: (p) {
      final now = DateTime.now();
      if (now.difference(lastProgress) > const Duration(seconds: 4)) {
        lastProgress = now;
        stderr.writeln(p);
      }
    },
  );
  if (response == null) {
    stderr.writeln(
      'the codegraph worker stopped before answering; see '
      '${ws.relative(WorkerState.logPath(ws))}',
    );
    return Exit.failed;
  }
  final out = response['out'] as String? ?? '';
  if (out.isNotEmpty) stdout.writeln(out);
  return response['exit'] as int? ?? Exit.failed;
}

Future<int> _doctor(Workspace ws, Command c) async {
  if (c.stop || c.restart) {
    await stopWorker(ws);
    if (c.stop) {
      stdout.writeln('worker stopped');
      return 0;
    }
  }
  if (c.warm || c.restart) {
    if (ws.unresolvableReason != null) return c.warm ? 0 : Exit.cannotAnalyze;
    final state = await ensureWorker(ws, wait: const Duration(seconds: 20));
    if (c.restart) {
      stdout.writeln(
        state == null ? 'worker failed to start' : 'worker restarted',
      );
    }
    return 0;
  }
  final lines = <String>[
    'codegraph $codegraphVersion',
    'workspace: ${ws.root}',
  ];
  final reason = ws.unresolvableReason;
  lines.add('package config: ${reason ?? 'ok'}');
  final sdkPath = sdkPathForAnalysis();
  final sdk = sdkVersion(sdkPath);
  lines.add(
    'dart sdk: ${sdk ?? 'not found'}'
    '${sdkPath == null ? ' (the running VM)' : ' ($sdkPath)'}',
  );
  final understood = analyzerLanguageVersion();
  lines.add('bundled analyzer understands Dart up to $understood');
  if (sdk != null && _newer(sdk, understood)) {
    lines.add(
      'warning: the SDK is newer than the bundled analyzer; code using new '
      'language features may not resolve. Update codegraph.',
    );
  }
  final state = WorkerState.read(ws);
  if (state == null) {
    lines.add(
      'worker: not running (starts on the first refs, impact, rename or show <symbol>)',
    );
  } else {
    final s = await sendToWorker(state, {
      'type': 'status',
    }, connectTimeout: const Duration(milliseconds: 800));
    if (s == null) {
      lines.add('worker: not responding (pid ${state.pid}); doctor --restart');
    } else {
      lines.add(
        'worker: ${s['version']} pid ${s['pid']}, ${s['phase']}, '
        '${s['files']} files, ${s['indexed']} indexed, ${s['rssMb']}MB, '
        'up ${s['uptimeSeconds']}s, exits after ${s['idleMinutes']} idle minutes'
        '${s['fineDeps'] == true ? ', fine dependencies' : ''}'
        '${s['error'] != null ? ', error: ${s['error']}' : ''}',
      );
    }
  }
  final others = Registry.entries().where((e) => e.root != ws.root).toList();
  lines.add(
    'other workers on this machine: ${others.length} (cap ${Registry.cap})'
    '${others.isEmpty ? '' : ': ${others.map((e) => e.root).join(', ')}'}',
  );
  stdout.writeln(lines.join('\n'));
  return reason == null ? 0 : Exit.cannotAnalyze;
}

bool _newer(String sdk, String languageVersion) {
  final a = sdk.split(RegExp(r'[.-]')).take(2).map(int.tryParse).toList();
  final b = languageVersion.split('.').map(int.tryParse).toList();
  if (a.length < 2 || a.contains(null) || b.contains(null)) return false;
  return a[0]! > b[0]! || (a[0] == b[0] && a[1]! > b[1]!);
}

int _print(Result r, Command c) {
  stdout.writeln(r.render(asJson: c.json, limit: c.limit));
  return r.exit;
}

int _usage(String message) {
  stderr.writeln('usage: $message');
  return Exit.usage;
}
