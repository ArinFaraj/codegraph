// Every analyzed file's parse-only outline, plus the import graph between
// them. The CLI loads it from a cache in .dart_tool/codegraph/; the worker
// keeps it in memory and refreshes it from the analyzer's change list.
import 'dart:convert';
import 'dart:io';

import 'files.dart';
import 'outline_model.dart';
import 'outline_parse.dart';
import 'workspace.dart';

export 'outline_model.dart';

const _cacheVersion = 8;

/// Every analyzed file's outline, refreshed from disk on load.
class OutlineIndex {
  OutlineIndex._(this.workspace, this.files, this._packageRoots);

  final Workspace workspace;

  /// Keyed by workspace-relative path.
  final Map<String, FileOutline> files;
  final Map<String, String> _packageRoots;

  Map<String, List<String>>? _importers;

  /// The cold path: every analyzed file, reusing the on-disk cache for files
  /// the tracker says have not changed, and writing it back when any did.
  static OutlineIndex load(Workspace ws) {
    final cacheFile = File('${ws.stateDir}/outline.json');
    Map<String, dynamic>? cache;
    try {
      final j = jsonDecode(cacheFile.readAsStringSync());
      if (j is Map<String, dynamic> && j['v'] == _cacheVersion) cache = j;
    } catch (_) {}
    final tracker = cache == null
        ? FileTracker(ws)
        : FileTracker.fromJson(ws, cache['tracker'] as Map<String, dynamic>);
    final cached = (cache?['files'] as Map<String, dynamic>?) ?? const {};
    final delta = tracker.sync();
    final stale = {...delta.added, ...delta.changed};

    final files = <String, FileOutline>{};
    for (final rel in tracker.files) {
      final entry = cached[rel];
      if (!stale.contains(rel) && entry is Map<String, dynamic>) {
        files[rel] = FileOutline.fromJson(rel, entry);
        continue;
      }
      try {
        files[rel] = parseOutline(
          rel,
          File(ws.absolute(rel)).readAsStringSync(),
        );
      } on FileSystemException {
        continue;
      }
    }
    if (cache == null || !delta.isEmpty) {
      try {
        Directory(ws.stateDir).createSync(recursive: true);
        File('${cacheFile.path}.$pid.tmp')
          ..writeAsStringSync(
            jsonEncode({
              'v': _cacheVersion,
              'tracker': tracker.toJson(),
              'files': {for (final e in files.entries) e.key: e.value.toJson()},
            }),
          )
          ..renameSync(cacheFile.path);
      } catch (_) {}
    }
    return OutlineIndex._(ws, files, ws.packageRoots());
  }

  /// The worker's path: an outline of [files] parsed from [read], kept in
  /// memory and updated by [refresh] from the analyzer's own change list.
  static OutlineIndex inMemory(
    Workspace ws,
    Iterable<String> files,
    String Function(String rel) read,
  ) {
    final index = OutlineIndex._(ws, {}, ws.packageRoots());
    index.refresh(files, read);
    return index;
  }

  /// Re-parses [changed] files (workspace-relative) and drops deleted ones.
  void refresh(Iterable<String> changed, String Function(String rel) read) {
    for (final rel in changed) {
      try {
        files[rel] = parseOutline(rel, read(rel));
      } on FileSystemException {
        files.remove(rel);
      }
    }
    _importers = null;
    _mentionCounts = null;
  }

  /// Resolves an import/export/part URI written in [fromRel] to a
  /// workspace-relative path, or null when it points outside the workspace.
  String? resolveUri(String fromRel, String uri) {
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final rest = uri.substring(8);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final root = _packageRoots[rest.substring(0, slash)];
      if (root == null) return null;
      final rel = workspace.relativeOrNull(
        '$root/lib/${rest.substring(slash + 1)}',
      );
      return files.containsKey(rel) ? rel : null;
    }
    final dir = fromRel.contains('/')
        ? fromRel.substring(0, fromRel.lastIndexOf('/'))
        : '';
    final rel = workspace.relativeOrNull(dir.isEmpty ? uri : '$dir/$uri');
    return files.containsKey(rel) ? rel : null;
  }

  /// Files this file imports or exports, resolved inside the workspace.
  List<(String, UriDirective)> dependencies(String rel) {
    final f = files[rel];
    if (f == null) return const [];
    return [
      for (final d in f.directives)
        if (d.kind.isDependency)
          if (resolveUri(rel, d.uri) case final target?) (target, d),
    ];
  }

  /// Files that import or export [rel].
  List<String> importers(String rel) {
    final map = _importers ??= () {
      final m = <String, List<String>>{};
      for (final from in files.keys) {
        for (final (to, _) in dependencies(from)) {
          (m[to] ??= []).add(from);
        }
      }
      for (final l in m.values) {
        l.sort();
      }
      return m;
    }();
    return map[rel] ?? const [];
  }

  Map<String, int>? _mentionCounts;

  /// Number of files other than [exceptFile] whose tokens mention [name].
  int mentions(String name, {String? exceptFile}) {
    final counts = _mentionCounts ??= () {
      final m = <String, int>{};
      for (final f in files.values) {
        for (final id in f.identifiers) {
          m[id] = (m[id] ?? 0) + 1;
        }
      }
      return m;
    }();
    final own =
        exceptFile != null &&
            (files[exceptFile]?.identifiers.contains(name) ?? false)
        ? 1
        : 0;
    return (counts[name] ?? 0) - own;
  }
}
