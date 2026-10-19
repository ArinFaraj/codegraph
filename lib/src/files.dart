// Which files `dart analyze` would analyze, and what changed since the last
// look. One stat per known file and per directory holding one; the context
// roots are re-walked only when a directory or an analysis config changed,
// because adding or deleting a file changes its parent directory.
import 'dart:io';

import 'workspace.dart';

class FileDelta {
  FileDelta(this.added, this.changed, this.removed, {required this.config});

  final List<String> added;
  final List<String> changed;
  final List<String> removed;

  /// A pubspec, analysis options file or the package config changed, so the
  /// set of analyzed files and how they resolve may have changed too.
  final bool config;

  bool get isEmpty =>
      added.isEmpty && changed.isEmpty && removed.isEmpty && !config;

  Iterable<String> get all => [...added, ...changed, ...removed];
}

class FileTracker {
  FileTracker(this.workspace);

  factory FileTracker.fromJson(Workspace ws, Map<String, dynamic> j) =>
      FileTracker(ws)
        .._files.addAll((j['files'] as Map).cast<String, String>())
        .._dirs.addAll((j['dirs'] as Map).cast<String, String>())
        .._config.addAll((j['config'] as Map).cast<String, String>());

  final Workspace workspace;

  /// Workspace-relative file to stamp.
  final Map<String, String> _files = {};
  final Map<String, String> _dirs = {};
  final Map<String, String> _config = {};

  Iterable<String> get files => _files.keys;

  Map<String, Object?> toJson() => {
    'files': _files,
    'dirs': _dirs,
    'config': _config,
  };

  FileDelta sync() {
    final config =
        _config.isNotEmpty &&
        _config.entries.any((e) => _stamp(e.key) != e.value);
    final rescan =
        config ||
        _dirs.isEmpty ||
        _dirs.entries.any((e) => _stamp(e.key) != e.value);

    final added = <String>[];
    final removed = <String>[];
    if (rescan) {
      final now = {
        for (final abs in workspace.analyzedFiles()) workspace.relative(abs),
      };
      for (final rel in now) {
        if (!_files.containsKey(rel)) {
          added.add(rel);
          _files[rel] = _stamp(workspace.absolute(rel));
        }
      }
      for (final rel in _files.keys.toList()) {
        if (!now.contains(rel)) {
          removed.add(rel);
          _files.remove(rel);
        }
      }
      _dirs
        ..clear()
        ..addAll(
          {
            for (final rel in _files.keys) _parent(workspace.absolute(rel)): '',
          }.map((dir, _) => MapEntry(dir, _stamp(dir))),
        );
      _config
        ..clear()
        ..addAll({for (final f in workspace.configFiles()) f: _stamp(f)});
    }

    final changed = <String>[];
    final fresh = added.toSet();
    for (final e in _files.entries) {
      if (fresh.contains(e.key)) continue;
      final stamp = _stamp(workspace.absolute(e.key));
      if (stamp != e.value) {
        changed.add(e.key);
        _files[e.key] = stamp;
      }
    }
    return FileDelta(added, changed, removed, config: config);
  }

  /// Records the current stamps of files this process just wrote, so the
  /// next [sync] does not report them again.
  void restamp(Iterable<String> paths) {
    for (final rel in paths) {
      if (_files.containsKey(rel))
        _files[rel] = _stamp(workspace.absolute(rel));
    }
  }
}

String _parent(String path) => path.substring(0, path.lastIndexOf('/'));

String _stamp(String path) {
  final s = FileStat.statSync(path);
  return s.type == FileSystemEntityType.notFound
      ? 'missing'
      : '${s.modified.microsecondsSinceEpoch}:${s.size}';
}
