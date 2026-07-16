import 'dart:convert';
import 'dart:io';

class AtomicTextEdit {
  const AtomicTextEdit({
    required this.file,
    required this.offset,
    required this.length,
    required this.expected,
    required this.replacement,
  });

  final String file;
  final int offset;
  final int length;
  final String expected;
  final String replacement;
}

class AtomicEditException implements Exception {
  AtomicEditException(
    this.message, {
    this.ioFailure = false,
    this.details = const [],
    this.recoveryPaths = const [],
  });

  final String message;
  final bool ioFailure;
  final List<String> details;
  final List<String> recoveryPaths;

  @override
  String toString() => message;
}

class PreparedTextEdits {
  PreparedTextEdits(this.files);
  final List<PreparedTextFile> files;
}

class PreparedTextFile {
  PreparedTextFile({
    required this.path,
    required this.originalBytes,
    required this.updatedBytes,
    required this.mode,
  });

  final String path;
  final List<int> originalBytes;
  final List<int> updatedBytes;
  final int mode;
  String? stagedPath;
  String? backupPath;
}

/// Validates every edit and computes every output before any filesystem write.
PreparedTextEdits prepareTextEdits(List<AtomicTextEdit> edits) {
  final byCanonicalPath = <String, List<AtomicTextEdit>>{};
  final requestedPath = <String, String>{};
  for (final edit in edits) {
    final type = FileSystemEntity.typeSync(edit.file, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw AtomicEditException(
        'refusing to edit a symbolic link',
        details: [edit.file],
      );
    }
    if (type != FileSystemEntityType.file) {
      throw AtomicEditException(
        'edit target is not a regular file',
        details: [edit.file],
      );
    }
    final canonical = File(edit.file).resolveSymbolicLinksSync();
    final previous = requestedPath[canonical];
    if (previous != null && previous != edit.file) {
      throw AtomicEditException(
        'multiple paths refer to the same edit target',
        details: [previous, edit.file],
      );
    }
    requestedPath[canonical] = edit.file;
    byCanonicalPath.putIfAbsent(canonical, () => []).add(edit);
  }

  final prepared = <PreparedTextFile>[];
  for (final entry in byCanonicalPath.entries) {
    final file = File(entry.key);
    final originalBytes = file.readAsBytesSync();
    final hasBom = originalBytes.length >= 3 &&
        originalBytes[0] == 0xef &&
        originalBytes[1] == 0xbb &&
        originalBytes[2] == 0xbf;
    final body = hasBom ? originalBytes.sublist(3) : originalBytes;
    final original = utf8.decode(body);
    final sorted = [...entry.value]
      ..sort((a, b) => a.offset.compareTo(b.offset));
    AtomicTextEdit? previous;
    for (final edit in sorted) {
      if (edit.offset < 0 ||
          edit.length < 0 ||
          edit.offset + edit.length > original.length) {
        throw AtomicEditException(
          'edit span is outside the current file',
          details: ['${edit.file}:${edit.offset}+${edit.length}'],
        );
      }
      if (edit.length != edit.expected.length ||
          original.substring(edit.offset, edit.offset + edit.length) !=
              edit.expected) {
        throw AtomicEditException(
          'source changed since the semantic index was built',
          details: ['${edit.file}:${edit.offset} expected ${edit.expected}'],
        );
      }
      if (previous != null && edit.offset < previous.offset + previous.length) {
        final duplicate =
            edit.offset == previous.offset && edit.length == previous.length;
        throw AtomicEditException(
          duplicate ? 'duplicate edit span' : 'overlapping edit spans',
          details: ['${edit.file}:${edit.offset}'],
        );
      }
      previous = edit;
    }

    var updated = original;
    for (final edit in sorted.reversed) {
      updated = updated.replaceRange(
        edit.offset,
        edit.offset + edit.length,
        edit.replacement,
      );
    }
    prepared.add(PreparedTextFile(
      path: entry.key,
      originalBytes: originalBytes,
      updatedBytes: [
        if (hasBom) ...const [0xef, 0xbb, 0xbf],
        ...utf8.encode(updated),
      ],
      mode: file.statSync().mode,
    ));
  }
  prepared.sort((a, b) => a.path.compareTo(b.path));
  return PreparedTextEdits(prepared);
}

typedef AtomicEditHook = void Function(int index, String path);

/// Stages every output beside its target, revalidates every original, then
/// installs the staged files. A failed install restores every attempted target
/// from a sibling backup in reverse order. Portable filesystems cannot provide
/// one atomic operation across multiple paths; this is transaction-like,
/// rollback-backed application with recovery paths retained on rollback error.
List<String> applyPreparedTextEdits(
  PreparedTextEdits prepared, {
  AtomicEditHook? beforeInstall,
  AtomicEditHook? beforeRollback,
}) {
  try {
    for (var i = 0; i < prepared.files.length; i++) {
      final item = prepared.files[i];
      item.stagedPath = _uniqueSibling(item.path, 'stage', i);
      _writeExclusive(item.stagedPath!, item.updatedBytes, item.mode);
      item.backupPath = _uniqueSibling(item.path, 'backup', i);
      _writeExclusive(item.backupPath!, item.originalBytes, item.mode);
    }
    for (final item in prepared.files) {
      if (!_bytesEqual(File(item.path).readAsBytesSync(), item.originalBytes)) {
        throw AtomicEditException(
          'source changed while rename output was being staged',
          details: [item.path],
        );
      }
    }
  } catch (error) {
    _cleanupUncommitted(prepared.files);
    if (error is AtomicEditException) rethrow;
    throw AtomicEditException(
      'could not stage rename output: $error',
      ioFailure: true,
    );
  }

  final attempted = <PreparedTextFile>[];
  try {
    for (var i = 0; i < prepared.files.length; i++) {
      final item = prepared.files[i];
      beforeInstall?.call(i, item.path);
      // Revalidate immediately before each replacement, not only once before
      // the install loop. If a later target changes while earlier targets are
      // being installed, rollback the earlier work without overwriting the
      // concurrent edit to this target.
      if (!_bytesEqual(File(item.path).readAsBytesSync(), item.originalBytes)) {
        throw AtomicEditException(
          'source changed immediately before rename installation',
          details: [item.path],
        );
      }
      attempted.add(item);
      File(item.stagedPath!).renameSync(item.path);
      item.stagedPath = null;
    }
  } catch (error) {
    final recovery = <String>[];
    for (var i = attempted.length - 1; i >= 0; i--) {
      final item = attempted[i];
      try {
        beforeRollback?.call(i, item.path);
        File(item.backupPath!).renameSync(item.path);
        item.backupPath = null;
      } catch (_) {
        if (item.backupPath case final backup?) recovery.add(backup);
      }
    }
    _cleanupAfterRollback(prepared.files, recovery.toSet());
    throw AtomicEditException(
      recovery.isEmpty
          ? 'rename application failed; all attempted files were restored'
          : 'rename application failed and rollback was incomplete',
      ioFailure: true,
      details: ['$error'],
      recoveryPaths: recovery,
    );
  }

  final retainedBackups = <String>[];
  for (final item in prepared.files) {
    final backup = item.backupPath;
    if (backup == null) continue;
    try {
      _deleteIfPresent(backup);
      item.backupPath = null;
    } on FileSystemException {
      // The edit is already installed successfully. Reporting this as an
      // apply failure would be actively misleading, so retain and return the
      // recovery artifact for the caller to disclose as cleanup work.
      retainedBackups.add(backup);
    }
  }
  return retainedBackups;
}

void _writeExclusive(String path, List<int> bytes, int mode) {
  final file = File(path)..createSync(exclusive: true);
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.writeFromSync(bytes);
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
  if (!Platform.isWindows) {
    final permission = (mode & 0xfff).toRadixString(8);
    final result = Process.runSync('chmod', [permission, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('could not preserve file mode', path);
    }
  }
}

String _uniqueSibling(String target, String kind, int index) {
  final file = File(target);
  final base = file.uri.pathSegments.last;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  for (var attempt = 0; attempt < 100; attempt++) {
    final path = '${file.parent.path}/.$base.codegraph-$kind-$pid-$stamp-'
        '$index-$attempt';
    if (!File(path).existsSync() && !Directory(path).existsSync()) return path;
  }
  throw FileSystemException('could not allocate sibling staging path', target);
}

void _cleanupUncommitted(Iterable<PreparedTextFile> files) {
  for (final item in files) {
    _deleteIfPresent(item.stagedPath);
    _deleteIfPresent(item.backupPath);
    item.stagedPath = null;
    item.backupPath = null;
  }
}

void _cleanupAfterRollback(
    Iterable<PreparedTextFile> files, Set<String> recovery) {
  for (final item in files) {
    _deleteIfPresent(item.stagedPath);
    item.stagedPath = null;
    if (item.backupPath case final backup?) {
      if (!recovery.contains(backup)) {
        _deleteIfPresent(backup);
        item.backupPath = null;
      }
    }
  }
}

void _deleteIfPresent(String? path) {
  if (path == null) return;
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
