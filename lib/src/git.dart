import 'dart:io';

import 'workspace.dart';

class Hunk {
  Hunk(this.start, this.end);

  /// New-side line range, inclusive. A pure deletion is the line it sat on.
  final int start;
  final int end;
}

class FileChange {
  FileChange(this.path, {this.deleted = false, List<Hunk>? hunks})
    : hunks = hunks ?? [];

  /// Workspace-relative.
  final String path;
  final bool deleted;
  final List<Hunk> hunks;
}

/// Dart files changed in the working tree (staged, unstaged and untracked),
/// or since the merge base with [base]. Null when git cannot answer.
List<FileChange>? gitChanges(Workspace ws, {String? base}) {
  ProcessResult git(List<String> args) =>
      Process.runSync('git', args, workingDirectory: ws.root);

  final top = git(['rev-parse', '--show-toplevel']);
  if (top.exitCode != 0) return null;
  final gitRoot = (top.stdout as String).trim();

  var from = 'HEAD';
  if (base != null) {
    final mb = git(['merge-base', base, 'HEAD']);
    if (mb.exitCode != 0) return null;
    from = (mb.stdout as String).trim();
  }
  final diff = git([
    'diff',
    '--no-color',
    '--no-renames',
    '-U0',
    from,
    '--',
    '*.dart',
  ]);
  if (diff.exitCode != 0) return null;

  final changes = <String, FileChange>{};
  FileChange? current;
  String? minusPath;
  for (final line in (diff.stdout as String).split('\n')) {
    if (line.startsWith('--- ')) {
      minusPath = line.startsWith('--- a/') ? line.substring(6) : null;
    } else if (line.startsWith('+++ ')) {
      if (line == '+++ /dev/null') {
        final rel = ws.relative('$gitRoot/$minusPath');
        current = changes[rel] = FileChange(rel, deleted: true);
      } else {
        final rel = ws.relative('$gitRoot/${line.substring(6)}');
        current = changes[rel] = FileChange(rel);
      }
    } else if (line.startsWith('@@') && current != null && !current.deleted) {
      final m = RegExp(r'\+(\d+)(?:,(\d+))?').firstMatch(line);
      if (m == null) continue;
      final start = int.parse(m.group(1)!);
      final count = int.parse(m.group(2) ?? '1');
      current.hunks.add(
        count == 0
            ? Hunk(start == 0 ? 1 : start, start == 0 ? 1 : start)
            : Hunk(start, start + count - 1),
      );
    }
  }

  final untracked = git([
    'ls-files',
    '--others',
    '--exclude-standard',
    '--',
    '*.dart',
  ]);
  if (untracked.exitCode == 0) {
    for (final p in (untracked.stdout as String).split('\n')) {
      if (p.trim().isEmpty) continue;
      final rel = ws.relative(ws.absolute(p));
      final lines = File(ws.absolute(rel)).readAsLinesSync().length;
      changes[rel] = FileChange(rel, hunks: [Hunk(1, lines == 0 ? 1 : lines)]);
    }
  }
  return changes.values
      .where((c) => !c.path.startsWith('/') && !isGeneratedFile(c.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}
