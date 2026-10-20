import 'check.dart';
import 'move.dart';
import 'find.dart';
import 'refs.dart';
import 'rename.dart';
import 'request.dart';
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
  });

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
}

/// Rebuilds a request on the worker side. One line per verb; each request
/// knows its own fields.
WorkerRequest decodeRequest(Map<String, dynamic> j) => switch (j['verb']) {
  'check' => CheckRequest.fromJson(j),
  'find' => FindRequest.fromJson(j),
  'refs' => RefsRequest.fromJson(j),
  'show' => ShowRequest.fromJson(j),
  'rename' => RenameRequest.fromJson(j),
  'move' => MoveRequest.fromJson(j),
  final v => throw FormatException('unknown worker verb $v'),
};
