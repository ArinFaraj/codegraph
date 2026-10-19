import 'rename.dart';
import 'result.dart';

class RefusalAnswer extends Answer {
  RefusalAnswer(this.refusal);
  final Refusal refusal;

  @override
  String get verb => 'rename';

  @override
  int get exit => Exit.refused;

  @override
  void write(TextOut out) {
    out.header('${refusal.kind.label}: ${refusal.reason}');
    for (final d in refusal.details) {
      out.row('  $d');
    }
    if (refusal.kind == RefusalKind.unsupported) {
      out.footer(
        'codegraph cannot compute this rename yet. Renaming by hand is fine; '
        'run `dart analyze` afterwards.',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'refused': {
      'kind': refusal.kind.label,
      'reason': refusal.reason,
      'details': refusal.details,
    },
  };
}

class RenameAnswer extends Answer {
  RenameAnswer(this.plan, this.applied);

  final RenamePlan plan;

  /// Null for a dry run.
  final Applied? applied;

  @override
  String get verb => 'rename';

  @override
  int get exit => switch (applied) {
    null || AppliedClean() => Exit.ok,
    RolledBack() => Exit.refused,
    NotApplied() => Exit.failed,
  };

  @override
  void write(TextOut out) {
    final files = plan.edits.map((e) => e.path).toSet();
    final t = plan.target;
    out.header(
      '${applied == null ? 'would rename' : 'renaming'} ${t.kind} '
      '${t.qualified} -> ${plan.newName}: ${plural(plan.edits.length, 'edit')} '
      'in ${plural(files.length, 'file')}'
      '${applied == null ? ' (dry run; --apply to write)' : ''}',
    );
    for (final e in plan.edits) {
      out.row('  ${e.path}:${e.line}  ${e.source}');
    }
    for (final w in plan.warnings) {
      out.footer('warning: $w');
    }
    switch (applied) {
      case null:
        break;
      case AppliedClean(:final checkedFiles):
        out.footer(
          'applied. Analysis of ${plural(checkedFiles, 'affected file')} '
          'shows no new errors.',
        );
      case RolledBack(:final errors):
        out.footer(
          'rolled back: the rename introduced ${plural(errors.length, 'error')}, '
          'so every file was restored:',
        );
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

  @override
  Map<String, Object?> toJson() => {
    'target': plan.target.toJson(),
    'newName': plan.newName,
    'edits': [
      for (final e in plan.edits)
        {'path': e.path, 'line': e.line, 'offset': e.offset},
    ],
    'warnings': plan.warnings,
    if (applied != null)
      'applied': switch (applied!) {
        AppliedClean(:final checkedFiles) => {
          'result': 'applied',
          'checkedFiles': checkedFiles,
        },
        RolledBack(:final errors) => {
          'result': 'rolled back',
          'errors': errors,
        },
        NotApplied(:final message, :final details) => {
          'result': 'not applied',
          'message': message,
          'details': details,
        },
      },
  };
}
