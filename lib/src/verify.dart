// What an applied change did to the build: the errors a set of files had
// before, compared with after. Rename and move both refuse to keep a change
// that introduced one.
import 'analysis.dart';
import 'engine.dart';

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

/// Error counts by diagnostic code, per file, taken before a change.
class ErrorBaseline {
  ErrorBaseline._(this._counts);

  final Map<String, Map<String, int>> _counts;

  int get fileCount => _counts.length;

  static Future<ErrorBaseline> take(
    Engine engine,
    Iterable<String> files,
  ) async {
    return ErrorBaseline._({
      for (final f in files.toSet())
        f: _countByCode(await engine.analysis.errors(f)),
    });
  }

  /// Errors present now that were not before, as `path:line  message`.
  /// [renamed] maps a file's old path to its new one, for files that moved.
  Future<List<String>> introduced(
    Engine engine, {
    Map<String, String> renamed = const {},
  }) async {
    final out = <String>[];
    for (final e in _counts.entries) {
      final path = renamed[e.key] ?? e.key;
      final now = await engine.analysis.errors(path);
      final counts = _countByCode(now);
      for (final d in now) {
        final code = d.code;
        if ((counts[code] ?? 0) > (e.value[code] ?? 0)) {
          out.add('$path:${d.line}  ${d.message}');
        }
      }
    }
    return out;
  }
}

Map<String, int> _countByCode(List<Problem> problems) {
  final out = <String, int>{};
  for (final d in problems) {
    final code = d.code;
    out[code] = (out[code] ?? 0) + 1;
  }
  return out;
}

/// Tells the analyzer and the engine's caches about files this process wrote.
Future<void> filesWritten(Engine engine, List<String> files) async {
  await engine.analysis.notifyChanged(files);
  engine.filesChanged(files);
}
