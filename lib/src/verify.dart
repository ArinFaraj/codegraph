// What an applied change did to the build: the errors a set of files had
// before, compared with after. Rename and move both refuse to keep a change
// that introduced one.
import 'engine.dart';
import 'problem_counts.dart';
import 'result.dart';

sealed class Applied {}

class AppliedClean extends Applied {
  AppliedClean(this.checkedFiles);
  final int checkedFiles;
}

class RolledBack extends Applied {
  RolledBack(this.errors);
  final List<String> errors;
}

class NotApplied extends Applied {
  NotApplied(this.message, this.details);
  final String message;
  final List<String> details;
}

/// The exit code of a change that was [applied], or of a dry run when null.
int appliedExit(Applied? applied) => switch (applied) {
  null || AppliedClean() => Exit.ok,
  RolledBack() => Exit.refused,
  NotApplied() => Exit.failed,
};

/// What happened to an applied change, as footer lines. [done] says what a
/// clean change did ("applied", "moved"); [rolledBack] heads the errors.
void writeApplied(
  TextOut out,
  Applied? applied, {
  required String done,
  required String Function(List<String> errors) rolledBack,
}) {
  switch (applied) {
    case null:
      break;
    case AppliedClean(:final checkedFiles):
      out.footer(
        '$done. Analysis of ${plural(checkedFiles, 'affected file')} '
        'shows no new errors.',
      );
    case RolledBack(:final errors):
      out.footer(rolledBack(errors));
      for (final e in errors.take(15)) {
        out.footer('  $e');
      }
    case NotApplied(:final message, :final details):
      out.footer('not applied: $message');
      for (final d in details) {
        out.footer('  $d');
      }
  }
}

Map<String, Object?> appliedJson(Applied applied) => switch (applied) {
  AppliedClean(:final checkedFiles) => {
    'result': 'applied',
    'checkedFiles': checkedFiles,
  },
  RolledBack(:final errors) => {'result': 'rolled back', 'errors': errors},
  NotApplied(:final message, :final details) => {
    'result': 'not applied',
    'message': message,
    'details': details,
  },
};

/// The errors every file a change can reach had before it: the changed
/// files and everything depending on them, transitively, as `check` scopes.
class ErrorBaseline {
  ErrorBaseline._(this._before);

  final Map<String, ProblemCounts> _before;

  int get fileCount => _before.length;

  static Future<ErrorBaseline> take(
    Engine engine,
    Iterable<String> changed,
  ) async {
    final scope = engine.outline.affectedBy(changed).toList();
    final errors = await Future.wait(scope.map(engine.analysis.errors));
    return ErrorBaseline._({
      for (var i = 0; i < scope.length; i++)
        scope[i]: ProblemCounts.of(errors[i], byCode),
    });
  }

  /// Errors present now that were not before, as `path:line  message`.
  /// [renamed] maps a file's old path to its new one, for files that moved.
  Future<List<String>> introduced(
    Engine engine, {
    Map<String, String> renamed = const {},
  }) async {
    final before = [
      for (final e in _before.entries) (renamed[e.key] ?? e.key, e.value),
    ];
    final now = await Future.wait([
      for (final (path, _) in before) engine.analysis.errors(path),
    ]);
    return [
      for (var i = 0; i < before.length; i++)
        for (final e in before[i].$2.newIn(now[i]))
          '${before[i].$1}:${e.line}  ${e.message}',
    ];
  }
}

/// Tells the analyzer and the engine's caches about files this process wrote.
Future<void> filesWritten(Engine engine, List<String> files) async {
  await engine.analysis.notifyChanged(files);
  engine.filesChanged(files);
}
