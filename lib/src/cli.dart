import 'dart:io';

import 'client.dart';
import 'commands.dart';
import 'doctor.dart';
import 'impact.dart';
import 'native_install.dart' as native_install;
import 'outline.dart';
import 'result.dart';
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

symbols: Name, Owner.member, path/to/file.dart:name, or path/to/file.dart:LINE
         (the outermost declaration named on that line)
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
  if (argv.first == 'install-native') {
    return native_install.run(argv.skip(1).toList());
  }

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
      'no pubspec.yaml here or above; run codegraph inside a Dart or Flutter '
      'package',
    );
    return Exit.cannotAnalyze;
  }

  int print(Answer a) {
    stdout.writeln(a.render(asJson: c.json, limit: c.limit));
    return a.exit;
  }

  switch (c.verb) {
    case 'find':
      if (c.args.length != 1) return _usage('codegraph find <name>');
      return print(find(OutlineIndex.load(ws), c.args.single));
    case 'why':
      if (c.args.length != 2) return _usage('codegraph why <fileA> <fileB>');
      return print(why(OutlineIndex.load(ws), c.args[0], c.args[1]));
    case 'show':
      if (c.args.length != 1) return _usage('codegraph show <file|dir|symbol>');
      final idx = OutlineIndex.load(ws);
      return switch (classifyArg(idx, c.args.single, directories: true)) {
        FileArg(:final path) => print(showFile(idx, path)),
        DirArg(:final path) => print(showArea(idx, path)),
        ChoiceArg(:final candidates) => print(
          FileChoiceAnswer('show', c.args.single, candidates),
        ),
        SymbolArg(:final query) => _ask(
          ws,
          ShowRequest(query, json: c.json, limit: c.limit),
        ),
      };
    case 'refs':
      if (c.args.length != 1) return _usage('codegraph refs <symbol>');
      return _ask(ws, RefsRequest(c.args.single, json: c.json, limit: c.limit));
    case 'impact':
      if (c.args.length != (c.diff ? 0 : 1)) {
        return _usage(
          'codegraph impact <symbol|file>, or impact --diff [--base <ref>]',
        );
      }
      if (c.diff) {
        return _ask(
          ws,
          ImpactRequest(DiffSeed(c.base), json: c.json, limit: c.limit),
        );
      }
      final idx = OutlineIndex.load(ws);
      final ImpactSeed seed;
      switch (classifyArg(idx, c.args.single, directories: false)) {
        case FileArg(:final path):
          seed = FileSeed(path);
        case SymbolArg(:final query):
          seed = SymbolSeed(query);
        case ChoiceArg(:final candidates):
          return print(FileChoiceAnswer('impact', c.args.single, candidates));
        case DirArg():
          return _usage('codegraph impact <symbol|file>');
      }
      return _ask(ws, ImpactRequest(seed, json: c.json, limit: c.limit));
    case 'rename':
      if (c.args.length != 2) {
        return _usage('codegraph rename <symbol> <newName> [--apply]');
      }
      return _ask(
        ws,
        RenameRequest(
          c.args[0],
          c.args[1],
          apply: c.apply,
          json: c.json,
          limit: c.limit,
        ),
      );
    case 'doctor':
      return doctor(ws, warm: c.warm, stop: c.stop, restart: c.restart);
  }
  return _usage('unknown verb "${c.verb}"; run codegraph help');
}

/// Sends [request] to this checkout's worker, starting it when needed, and
/// prints its answer. Progress goes to stderr, at most every four seconds.
Future<int> _ask(Workspace ws, WorkerRequest request) async {
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
    {'type': 'run', 'request': request.toJson()},
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

int _usage(String message) {
  stderr.writeln('usage: $message');
  return Exit.usage;
}
