import 'dart:io';

import 'check.dart';
import 'engine.dart';
import 'find.dart';
import 'move.dart';
import 'refs.dart';
import 'rename.dart';
import 'result.dart';
import 'show.dart';

/// What the user typed, with flags separated from arguments.
class Command {
  Command(
    this.verb,
    this.args, {
    this.json = false,
    this.limit = 40,
    this.apply = false,
    this.warm = false,
    this.stop = false,
    this.restart = false,
    this.help = false,
    this.context = 0,
    this.all = false,
    this.hook = false,
    this.error,
    this.cwd = '',
    this.since,
  });

  /// The part of a command the worker needs to answer it.
  factory Command.fromJson(Map<String, dynamic> j) => Command(
    j['verb'] as String,
    (j['args'] as List).cast<String>(),
    json: j['json'] as bool,
    limit: j['limit'] as int?,
    apply: j['apply'] as bool,
    context: j['context'] as int,
    all: j['all'] as bool,
    cwd: j['cwd'] as String,
    since: switch (j['since']) {
      final int t => DateTime.fromMicrosecondsSinceEpoch(t),
      _ => null,
    },
  );

  factory Command.parse(List<String> argv) {
    var verb = '';
    final args = <String>[];
    var json = false;
    int? limit = 40;
    var apply = false;
    var warm = false;
    var stop = false;
    var restart = false;
    var help = false;
    var context = 0;
    var all = false;
    var hook = false;
    String? error;
    for (var i = 0; i < argv.length; i++) {
      switch (argv[i]) {
        case '--json':
          json = true;
        case '--all':
          limit = null;
          all = true;
        case '--hook':
          hook = true;
        case '--apply':
          apply = true;
        case '--warm':
          warm = true;
        case '--stop':
          stop = true;
        case '--restart':
          restart = true;
        case '--help' || '-h':
          help = true;
        case '-C' || '--context':
          final n = i + 1 < argv.length ? int.tryParse(argv[i + 1]) : null;
          if (n == null || n < 0) {
            error = '${argv[i]} needs a number of lines';
          } else {
            context = n;
            i++;
          }
        case '--limit':
          final n = i + 1 < argv.length ? int.tryParse(argv[i + 1]) : null;
          if (n == null || n < 1) {
            error = '--limit needs a positive number';
          } else {
            limit = n;
            i++;
          }
        case final a when a.startsWith('--'):
          error = 'unknown flag $a';
        case final a when verb.isEmpty:
          verb = a;
        case final a:
          args.add(a);
      }
    }
    return Command(
      verb,
      args,
      json: json,
      limit: limit,
      apply: apply,
      warm: warm,
      stop: stop,
      restart: restart,
      help: help,
      context: context,
      all: all,
      hook: hook,
      error: error,
      cwd: Directory.current.path,
    );
  }

  final String verb;
  final List<String> args;
  final bool json;
  final int? limit;
  final bool apply;
  final bool warm;
  final bool stop;
  final bool restart;
  final bool help;

  /// `-C N`: lines of source shown around each use.
  final int context;

  /// `--all`: every row, and for `check`, the whole workspace.
  final bool all;

  /// `check --hook`: read a coding agent's hook input on stdin.
  final bool hook;
  final String? error;

  /// The directory the command was typed in; relative file arguments of
  /// `check` are read from it.
  final String cwd;

  /// For `check`: also every analyzed file modified at or after this time.
  final DateTime? since;

  Map<String, Object?> toJson() => {
    'verb': verb,
    'args': args,
    'json': json,
    'limit': limit,
    'apply': apply,
    'context': context,
    'all': all,
    'cwd': cwd,
    'since': since?.microsecondsSinceEpoch,
  };
}

/// A verb the worker answers: its usage line, whether a command's arguments
/// fit it, and how the worker answers it.
class Verb {
  const Verb(this.usage, this.accepts, this.run);

  final String usage;
  final bool Function(Command c) accepts;
  final Future<Answer> Function(Engine engine, Command c) run;
}

bool _one(Command c) => c.args.length == 1;

final workerVerbs = <String, Verb>{
  'check': Verb(
    'codegraph check [files...] or codegraph check --all',
    (c) => !c.all || c.args.isEmpty,
    (engine, c) => c.all
        ? checkAll(engine)
        : check(
            engine,
            paths: [
              for (final p in c.args) p.startsWith('/') ? p : '${c.cwd}/$p',
            ],
            since: c.since,
          ),
  ),
  'find': Verb(
    'codegraph find <name>',
    _one,
    (engine, c) async => find(engine.outline, c.args.single),
  ),
  'show': Verb(
    'codegraph show <file|dir|symbol>',
    _one,
    (engine, c) => show(engine, c.args.single),
  ),
  'refs': Verb(
    'codegraph refs <symbol>',
    _one,
    (engine, c) => refs(engine, c.args.single, context: c.context),
  ),
  'rename': Verb(
    'codegraph rename <symbol> <newName> [--apply], or '
    'rename <file.dart> <new/path.dart> [--apply]',
    (c) => c.args.length == 2,
    (engine, c) {
      final [from, to] = c.args;
      return from.endsWith('.dart') && to.endsWith('.dart')
          ? move(engine, from, to, apply: c.apply)
          : rename(engine, from, to, apply: c.apply);
    },
  ),
};
