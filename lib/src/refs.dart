// `refs`: every use of one declaration, grouped by role.
import 'classify.dart';
import 'engine.dart';
import 'request.dart';
import 'result.dart';
import 'symbols.dart';

Future<Answer> refs(Engine engine, String query) =>
    engine.withTarget('refs', query, (target) async {
      return RefsAnswer(
        target,
        await engine.usesOf(target.element),
        engine.analysis.fileCount,
      );
    });

class RefsRequest extends WorkerRequest {
  RefsRequest(this.query, {required super.json, required super.limit});

  RefsRequest.fromJson(Map<String, dynamic> j)
    : this(
        j['query'] as String,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  final String query;

  @override
  String get verb => 'refs';

  @override
  Map<String, Object?> get fields => {'query': query};

  @override
  Future<Answer> run(Engine engine) => refs(engine, query);
}

class RefsAnswer extends Answer {
  RefsAnswer(this.target, this.uses, this.analyzedFiles);

  final Target target;
  final List<Use> uses;
  final int analyzedFiles;

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
    writeUses(out, uses, withSource: true);
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
void writeUses(TextOut out, List<Use> uses, {required bool withSource}) {
  for (final ((inTest, role), group) in groupByRole(uses)) {
    out.section('${inTest ? 'tests, ' : ''}$role (${group.length}):');
    for (final u in group) {
      out.row(
        withSource ? '  ${u.location}  ${_clip(u.source)}' : '  ${u.location}',
      );
    }
  }
}

String _clip(String s) => s.length <= 110 ? s : '${s.substring(0, 107)}...';
