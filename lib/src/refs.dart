// `refs`: every use of one declaration, grouped by role.
import 'classify.dart';
import 'engine.dart';
import 'request.dart';
import 'result.dart';
import 'symbols.dart';

Future<Answer> refs(Engine engine, String query, {int context = 0}) =>
    engine.withEachTarget('refs', query, (target) async {
      final uses = await engine.usesOf(target.element);
      return RefsAnswer(
        target,
        uses,
        engine.analysis.fileCount,
        context: {
          if (context > 0)
            for (final u in uses)
              u.location: _around(engine.sources.text(u.path), u.line, context),
        },
      );
    });

/// Lines [line] - [n] to [line] + [n], numbered, with [line] marked.
String _around(String text, int line, int n) {
  final lines = text.split('\n');
  final last = (line + n).clamp(1, lines.length);
  final width = '$last'.length;
  return [
    for (var i = (line - n).clamp(1, lines.length); i <= last; i++)
      '    ${i == line ? '>' : ' '} ${'$i'.padLeft(width)}  ${lines[i - 1]}',
  ].join('\n');
}

class RefsRequest extends WorkerRequest {
  RefsRequest(
    this.query, {
    this.context = 0,
    required super.json,
    required super.limit,
  });

  RefsRequest.fromJson(Map<String, dynamic> j)
    : this(
        j['query'] as String,
        context: j['context'] as int? ?? 0,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  final String query;
  final int context;

  @override
  String get verb => 'refs';

  @override
  Map<String, Object?> get fields => {'query': query, 'context': context};

  @override
  Future<Answer> run(Engine engine) => refs(engine, query, context: context);
}

class RefsAnswer extends Answer {
  RefsAnswer(
    this.target,
    this.uses,
    this.analyzedFiles, {
    this.context = const {},
  });

  final Target target;
  final List<Use> uses;
  final int analyzedFiles;

  /// Numbered source around each use, by its location, when asked for.
  final Map<String, String> context;

  @override
  String get verb => 'refs';

  @override
  void write(TextOut out) {
    final files = uses.map((u) => u.path).toSet();
    final tests = uses.where((u) => u.inTest).map((u) => u.path).toSet().length;
    out.header(
      'refs ${target.qualified} (${target.kind}, ${target.location}): '
      '${plural(uses.length, 'use')} in ${plural(files.length, 'file')}'
      '${tests > 0 ? ' ($tests in tests)' : ''}',
    );
    if (uses.isEmpty) {
      out.footer('no uses in ${plural(analyzedFiles, 'analyzed file')}');
    }
    writeUses(out, uses, withSource: true, context: context);
  }

  @override
  Map<String, Object?> toJson() => {
    'target': target.toJson(),
    'uses': [for (final u in uses) useJson(u)],
  };
}

Map<String, Object?> useJson(Use u) => {
  'path': u.path,
  'line': u.line,
  'role': u.role.label,
  'test': u.inTest,
};

/// Writes [uses] grouped by role, library code before tests.
/// With [context], each use is followed by its numbered source lines.
void writeUses(
  TextOut out,
  List<Use> uses, {
  required bool withSource,
  Map<String, String> context = const {},
}) {
  for (final ((inTest, role), group) in groupByRole(uses)) {
    out.section('${inTest ? 'tests, ' : ''}$role (${group.length}):');
    for (final u in group) {
      if (context[u.location] case final lines?) {
        out.row('  ${u.location}\n$lines');
      } else {
        out.row(
          withSource
              ? '  ${u.location}  ${_clip(u.source)}'
              : '  ${u.location}',
        );
      }
    }
  }
}

String _clip(String s) => s.length <= 110 ? s : '${s.substring(0, 107)}...';
