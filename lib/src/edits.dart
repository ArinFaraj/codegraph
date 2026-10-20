// Several file changes applied together: every output is computed and staged
// before any target is touched, each target is checked unchanged just before
// it is replaced, and a failure puts back what was already replaced.
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
    this.details = const [],
    this.recoveryPaths = const [],
  });

  final String message;
  final List<String> details;
  final List<String> recoveryPaths;

  @override
  String toString() => message;
}

class PreparedTextEdits {
  PreparedTextEdits(this.files);
  final List<PreparedTextFile> files;

  /// The same changes undone: what was written is replaced by what was there,
  /// a created file is deleted and a deleted one recreated.
  PreparedTextEdits get reversed => PreparedTextEdits([
    for (final f in files)
      PreparedTextFile(
        path: f.path,
        originalBytes: f.updatedBytes,
        updatedBytes: f.originalBytes,
      ),
  ]);
}

class PreparedTextFile {
  PreparedTextFile({
    required this.path,
    required this.originalBytes,
    required this.updatedBytes,
  });

  final String path;

  /// Null when the file does not exist before the change.
  final List<int>? originalBytes;

  /// Null when the change deletes the file.
  final List<int>? updatedBytes;
  String? stagedPath;
  String? backupPath;

  /// Directories made to hold a created file, outermost first.
  final List<Directory> createdDirs = [];
}

/// Validates every change and computes every output before any filesystem
/// write: span [edits] in existing files, files to [create] with their text,
/// and files to [delete] with the text they must still have.
PreparedTextEdits prepareTextEdits(
  List<AtomicTextEdit> edits, {
  Map<String, String> create = const {},
  Map<String, String> delete = const {},
}) {
  final byCanonicalPath = <String, List<AtomicTextEdit>>{};
  final requestedPath = <String, String>{};
  void claim(String canonical, String requested) {
    final previous = requestedPath[canonical];
    if (previous != null && previous != requested) {
      throw AtomicEditException(
        'multiple paths refer to the same edit target',
        details: [previous, requested],
      );
    }
    requestedPath[canonical] = requested;
  }

  String existing(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw AtomicEditException(
        'refusing to edit a symbolic link',
        details: [path],
      );
    }
    if (type != FileSystemEntityType.file) {
      throw AtomicEditException(
        'edit target is not a regular file',
        details: [path],
      );
    }
    final canonical = File(path).resolveSymbolicLinksSync();
    claim(canonical, path);
    return canonical;
  }

  for (final edit in edits) {
    byCanonicalPath.putIfAbsent(existing(edit.file), () => []).add(edit);
  }

  final prepared = <PreparedTextFile>[];
  for (final entry in byCanonicalPath.entries) {
    final originalBytes = File(entry.key).readAsBytesSync();
    final (bom, original) = _decode(originalBytes);
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
          'source changed since it was analyzed',
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
    prepared.add(
      PreparedTextFile(
        path: entry.key,
        originalBytes: originalBytes,
        updatedBytes: [...bom, ...utf8.encode(updated)],
      ),
    );
  }

  for (final MapEntry(key: path, value: text) in delete.entries) {
    final canonical = existing(path);
    if (byCanonicalPath.containsKey(canonical)) {
      throw AtomicEditException(
        'a file is both edited and deleted',
        details: [path],
      );
    }
    final originalBytes = File(canonical).readAsBytesSync();
    if (_decode(originalBytes).$2 != text) {
      throw AtomicEditException(
        'source changed since it was analyzed',
        details: [path],
      );
    }
    prepared.add(
      PreparedTextFile(
        path: canonical,
        originalBytes: originalBytes,
        updatedBytes: null,
      ),
    );
  }

  for (final MapEntry(key: path, value: text) in create.entries) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw AtomicEditException('$path already exists', details: [path]);
    }
    claim(path, path);
    prepared.add(
      PreparedTextFile(
        path: path,
        originalBytes: null,
        updatedBytes: utf8.encode(text),
      ),
    );
  }
  prepared.sort((a, b) => a.path.compareTo(b.path));
  return PreparedTextEdits(prepared);
}

/// Stages every output beside its target, revalidates every original, then
/// installs the staged files. A failed install restores every attempted target
/// in reverse order; a backup that could not be put back is named in the
/// exception's recovery paths.
void applyPreparedTextEdits(PreparedTextEdits prepared) {
  try {
    for (var i = 0; i < prepared.files.length; i++) {
      final item = prepared.files[i];
      if (item.originalBytes == null) {
        item.createdDirs.addAll(_missingDirs(File(item.path).parent));
        File(item.path).parent.createSync(recursive: true);
      }
      if (item.updatedBytes case final bytes?) {
        item.stagedPath = _uniqueSibling(item.path, 'stage', i);
        _writeLike(item.stagedPath!, bytes, item);
      }
      if (item.originalBytes case final bytes?) {
        item.backupPath = _uniqueSibling(item.path, 'backup', i);
        _writeLike(item.backupPath!, bytes, item);
      }
    }
    for (final item in prepared.files) {
      _checkUnchanged(item, 'source changed while the edit was being staged');
    }
  } catch (error) {
    _cleanupUncommitted(prepared.files);
    if (error is AtomicEditException) rethrow;
    throw AtomicEditException('could not stage the edit: $error');
  }

  final attempted = <PreparedTextFile>[];
  try {
    for (final item in prepared.files) {
      _checkUnchanged(
        item,
        'source changed just before the edit was installed',
      );
      attempted.add(item);
      if (item.stagedPath case final staged?) {
        File(staged).renameSync(item.path);
        item.stagedPath = null;
      } else {
        File(item.path).deleteSync();
      }
    }
  } catch (error) {
    final recovery = <String>[];
    for (final item in attempted.reversed) {
      try {
        if (item.backupPath case final backup?) {
          File(backup).renameSync(item.path);
          item.backupPath = null;
        } else {
          _deleteIfPresent(item.path);
          _removeCreatedDirs(item);
        }
      } catch (_) {
        if (item.backupPath case final backup?) recovery.add(backup);
      }
    }
    _cleanupAfterRollback(prepared.files, recovery.toSet());
    throw AtomicEditException(
      recovery.isEmpty
          ? 'applying the edit failed; every attempted file was restored'
          : 'applying the edit failed and the restore was incomplete',
      details: ['$error'],
      recoveryPaths: recovery,
    );
  }

  for (final item in prepared.files) {
    try {
      _deleteIfPresent(item.backupPath);
    } on FileSystemException {
      continue;
    }
    item.backupPath = null;
    if (item.updatedBytes == null) _removeCreatedDirs(item);
  }
}

/// Puts back what [prepared] changed, with the same stage-then-rename
/// install. Used when an applied change turns out to break the build.
void restorePreparedTextEdits(PreparedTextEdits prepared) {
  final undo = prepared.reversed;
  for (var i = 0; i < undo.files.length; i++) {
    undo.files[i].createdDirs.addAll(prepared.files[i].createdDirs);
  }
  applyPreparedTextEdits(undo);
}

(List<int>, String) _decode(List<int> bytes) {
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  return (
    hasBom ? const [0xef, 0xbb, 0xbf] : const [],
    utf8.decode(hasBom ? bytes.sublist(3) : bytes),
  );
}

void _checkUnchanged(PreparedTextFile item, String message) {
  final file = File(item.path);
  final unchanged = switch (item.originalBytes) {
    null => !file.existsSync(),
    final bytes =>
      file.existsSync() && _bytesEqual(file.readAsBytesSync(), bytes),
  };
  if (!unchanged) throw AtomicEditException(message, details: [item.path]);
}

/// Writes [bytes] to the new file [path]. A copy of an existing target keeps
/// its permissions, which a fresh file would not.
void _writeLike(String path, List<int> bytes, PreparedTextFile item) {
  if (item.originalBytes != null) {
    File(item.path).copySync(path);
    File(path).writeAsBytesSync(bytes, flush: true);
  } else {
    final file = File(path)..createSync(exclusive: true);
    file.writeAsBytesSync(bytes, flush: true);
  }
}

String _uniqueSibling(String target, String kind, int index) {
  final file = File(target);
  final base = file.uri.pathSegments.last;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  for (var attempt = 0; attempt < 100; attempt++) {
    final path =
        '${file.parent.path}/.$base.codegraph-$kind-$pid-$stamp-'
        '$index-$attempt';
    if (!File(path).existsSync() && !Directory(path).existsSync()) return path;
  }
  throw FileSystemException('could not allocate sibling staging path', target);
}

/// [dir] and the ancestors of it that do not exist yet, outermost first.
List<Directory> _missingDirs(Directory dir) {
  final out = <Directory>[];
  for (var d = dir; !d.existsSync(); d = d.parent) {
    out.insert(0, d);
  }
  return out;
}

void _removeCreatedDirs(PreparedTextFile item) {
  for (final d in item.createdDirs.reversed) {
    if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
  }
}

void _cleanupUncommitted(Iterable<PreparedTextFile> files) {
  for (final item in files) {
    _deleteIfPresent(item.stagedPath);
    _deleteIfPresent(item.backupPath);
    item.stagedPath = null;
    item.backupPath = null;
    _removeCreatedDirs(item);
  }
}

void _cleanupAfterRollback(
  Iterable<PreparedTextFile> files,
  Set<String> recovery,
) {
  for (final item in files) {
    _deleteIfPresent(item.stagedPath);
    item.stagedPath = null;
    if (item.backupPath case final backup? when !recovery.contains(backup)) {
      _deleteIfPresent(backup);
      item.backupPath = null;
    }
    if (item.originalBytes == null) _removeCreatedDirs(item);
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
