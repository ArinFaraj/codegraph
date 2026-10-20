import 'dart:io';

import 'client.dart';
import 'commands.dart';
import 'doctor.dart';
import 'move.dart';
import 'refs.dart';
import 'rename.dart';
import 'request.dart';
import 'show.dart';
import 'native_install.dart' as native_install;
import 'outline.dart';
import 'result.dart';
import 'check.dart';
import 'check_hook.dart';
import 'find.dart';
import 'version.dart';
import 'worker.dart';
import 'workspace.dart';

const help =
    '''
codegraph $codegraphVersion - exact answers about a Dart or Flutter repository

  codegraph check [files...]          new errors, warnings and lints these files
                                      cause, in them and in everything that
                                      depends on them; no files: everything new
  codegraph check --all               every problem `dart analyze` reports,
                                      except analyzer plugins
  codegraph check --hook              for a coding agent's after-tool hook:
                                      reads the hook JSON on stdin, silent
                                      unless something new broke (exit 2)
  codegraph find <name>               where something is declared (instant)
  codegraph show <file|dir|symbol>    a file's outline, wiring and provider
                                      uses; a directory's pages and providers
                                      with their outside uses; or a symbol:
                                      source, subtypes, overrides, use counts
  codegraph refs <symbol> [-C N]      every use, path:line, grouped by role
                                      (ref.watch, call, implement, ...); -C N
                                      prints N lines of source around each
  codegraph rename <symbol> <new>     dry run of a complete rename; --apply
                                      writes it, re-analyzes the affected
                                      files, and rolls back on new errors
  codegraph rename <a.dart> <b.dart>  moves a file and rewrites every import
                                      and export of it, the same way
  codegraph doctor [--warm|--stop|--restart]
                                      worker and setup status

symbols: Name, Owner.member, path/to/file.dart:name, or path/to/file.dart:LINE
         (the outermost declaration named on that line)
flags:   --json, --limit N (default 40 rows), --all

check, refs, rename and show are answered by a background worker
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
  'path': 'show <file> (imports and importers)',
  'change': 'refs <symbol>, or check for what a change broke',
  'review': 'check, then the repository\'s own test selector',
  'diff': 'check, then the repository\'s own test selector',
  'affected-tests': 'the repository\'s own test selector',
  'impact':
      'refs <symbol> for its uses, check for what a change broke, and the '
      'repository\'s own test selector for tests',
  'why': 'show <file> (imports and importers)',
  'lint': 'nothing: architecture rules belong in the repository\'s tests',
  'build': 'nothing: there is nothing to build; answers are computed on demand',
  'daemon': 'doctor --warm / --stop',
  'init': 'nothing: no scaffolding is installed',
  'upgrade': 'nothing: no scaffolding is installed',
  'passport': 'show <dir>',
  'attention': 'nothing',
  'health': 'nothing',
  'unused': 'refs <symbol> (0 uses means unused)',
  'untested': 'refs <symbol> (tests are listed apart)',
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
  if (ws == null && c.verb == 'check' && c.hook) return Exit.ok;
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
    case 'check':
      if (c.hook) return checkHook(ws);
      if (c.all && c.args.isNotEmpty) {
        return _usage('codegraph check [files...] or codegraph check --all');
      }
      return _ask(
        ws,
        CheckRequest(
          paths: [for (final p in c.args) File(p).absolute.path],
          all: c.all,
          json: c.json,
          limit: c.limit,
        ),
      );
    case 'find' || 'show':
      if (c.args.length != 1) {
        return _usage(
          c.verb == 'find'
              ? 'codegraph find <name>'
              : 'codegraph show <file|dir|symbol>',
        );
      }
      final arg = c.args.single;
      if (c.verb == 'show') {
        return _ask(ws, ShowRequest(arg, json: c.json, limit: c.limit));
      }
      if (await readyWorker(ws) != null) {
        return _ask(ws, FindRequest(arg, json: c.json, limit: c.limit));
      }
      return print(find(OutlineIndex.load(ws), arg));
    case 'refs':
      if (c.args.length != 1) return _usage('codegraph refs <symbol>');
      return _ask(
        ws,
        RefsRequest(
          c.args.single,
          context: c.context,
          json: c.json,
          limit: c.limit,
        ),
      );
    case 'rename':
      if (c.args.length != 2) {
        return _usage(
          'codegraph rename <symbol> <newName> [--apply], or '
          'rename <file.dart> <new/path.dart> [--apply]',
        );
      }
      final [from, to] = c.args;
      return _ask(
        ws,
        from.endsWith('.dart') && to.endsWith('.dart')
            ? MoveRequest(
                from,
                to,
                apply: c.apply,
                json: c.json,
                limit: c.limit,
              )
            : RenameRequest(
                from,
                to,
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
  final worker = await ensureWorker(ws);
  if (worker == null) {
    stderr.writeln(
      'could not start the codegraph worker; see '
      '${ws.relative(workerLogPath(ws))}',
    );
    return Exit.failed;
  }
  var lastProgress = DateTime(0);
  final reply = await runOnWorker(
    worker,
    request,
    onProgress: (p) {
      final now = DateTime.now();
      if (now.difference(lastProgress) > const Duration(seconds: 4)) {
        lastProgress = now;
        stderr.writeln(p);
      }
    },
  );
  if (reply == null) {
    stderr.writeln(
      'the codegraph worker stopped before answering; see '
      '${ws.relative(workerLogPath(ws))}',
    );
    return Exit.failed;
  }
  if (reply.out.isNotEmpty) stdout.writeln(reply.out);
  return reply.exit;
}

int _usage(String message) {
  stderr.writeln('usage: $message');
  return Exit.usage;
}
