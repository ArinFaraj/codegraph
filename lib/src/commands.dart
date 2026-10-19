import 'engine.dart';
import 'rename.dart' as rename_verb;
import 'result.dart';

/// What the user typed, with flags separated from arguments.
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
    var help = false;
    String? error;
    for (var i = 0; i < argv.length; i++) {
      switch (argv[i]) {
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
          help = true;
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
      diff: diff,
      base: base,
      warm: warm,
      stop: stop,
      restart: restart,
      help: help,
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

/// A question for the worker, already classified by the client.
sealed class WorkerRequest {
  WorkerRequest({required this.json, required this.limit});

  factory WorkerRequest.fromJson(Map<String, dynamic> j) {
    final json = j['json'] as bool;
    final limit = j['limit'] as int?;
    return switch (j['verb']) {
      'refs' => RefsRequest(j['query'] as String, json: json, limit: limit),
      'show' => ShowRequest(j['query'] as String, json: json, limit: limit),
      'impact' => ImpactRequest(
        switch (j['seed']) {
          'file' => FileSeed(j['path'] as String),
          'diff' => DiffSeed(j['base'] as String?),
          _ => SymbolSeed(j['query'] as String),
        },
        json: json,
        limit: limit,
      ),
      'rename' => RenameRequest(
        j['query'] as String,
        j['newName'] as String,
        apply: j['apply'] as bool,
        json: json,
        limit: limit,
      ),
      final v => throw FormatException('unknown worker verb $v'),
    };
  }

  final bool json;
  final int? limit;

  Future<Answer> run(Engine engine);

  Map<String, Object?> get _fields;

  Map<String, Object?> toJson() => {'json': json, 'limit': limit, ..._fields};
}

class RefsRequest extends WorkerRequest {
  RefsRequest(this.query, {required super.json, required super.limit});
  final String query;

  @override
  Future<Answer> run(Engine engine) => engine.refs(query);

  @override
  Map<String, Object?> get _fields => {'verb': 'refs', 'query': query};
}

class ShowRequest extends WorkerRequest {
  ShowRequest(this.query, {required super.json, required super.limit});
  final String query;

  @override
  Future<Answer> run(Engine engine) => engine.showSymbol(query);

  @override
  Map<String, Object?> get _fields => {'verb': 'show', 'query': query};
}

class ImpactRequest extends WorkerRequest {
  ImpactRequest(this.seed, {required super.json, required super.limit});
  final ImpactSeed seed;

  @override
  Future<Answer> run(Engine engine) => engine.impact(seed);

  @override
  Map<String, Object?> get _fields => {
    'verb': 'impact',
    ...switch (seed) {
      SymbolSeed(:final query) => {'seed': 'symbol', 'query': query},
      FileSeed(:final path) => {'seed': 'file', 'path': path},
      DiffSeed(:final base) => {'seed': 'diff', 'base': base},
    },
  };
}

class RenameRequest extends WorkerRequest {
  RenameRequest(
    this.query,
    this.newName, {
    required this.apply,
    required super.json,
    required super.limit,
  });

  final String query;
  final String newName;
  final bool apply;

  @override
  Future<Answer> run(Engine engine) =>
      rename_verb.rename(engine, query, newName, apply: apply);

  @override
  Map<String, Object?> get _fields => {
    'verb': 'rename',
    'query': query,
    'newName': newName,
    'apply': apply,
  };
}
