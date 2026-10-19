// Every analyzed file's parse-only outline, plus the import graph between
// them. The CLI loads it from a cache in .dart_tool/codegraph/; the worker
// keeps it in memory and refreshes it from the analyzer's change list.
import 'dart:convert';
import 'dart:io';

import 'outline_model.dart';
import 'outline_parse.dart';
import 'workspace.dart';

export 'outline_model.dart';

const _cacheVersion = 6;

/// Every analyzed file's outline, refreshed from disk on load.
class OutlineIndex {
  OutlineIndex._(this.workspace, this.files, this._packageRoots);

  final Workspace workspace;

  /// Keyed by workspace-relative path.
  final Map<String, FileOutline> files;
  final Map<String, String> _packageRoots;

  Map<String, List<String>>? _importers;

  /// The cold path: every analyzed file, reusing the on-disk cache for files
  /// that have not changed and writing it back when anything did.
  static OutlineIndex load(Workspace ws) {
    final cacheFile = File('${ws.stateDir}/outline.json');
    Map<String, dynamic> cache = const {};
    if (cacheFile.existsSync()) {
      try {
        final j = jsonDecode(cacheFile.readAsStringSync());
        if (j is Map<String, dynamic> && j['v'] == _cacheVersion) cache = j;
      } catch (_) {}
    }
    final cachedFiles = (cache['files'] as Map<String, dynamic>?) ?? const {};
    final dirStamps = (cache['dirs'] as Map<String, dynamic>?) ?? const {};

    List<String>? fileList;
    if (dirStamps.isNotEmpty) {
      var dirsUnchanged = true;
      for (final e in dirStamps.entries) {
        if (_dirStamp(e.key) != e.value) {
          dirsUnchanged = false;
          break;
        }
      }
      if (dirsUnchanged) {
        fileList = [for (final k in cachedFiles.keys) ws.absolute(k)];
      }
    }
    fileList ??= ws.analyzedFiles();

    final files = <String, FileOutline>{};
    final newCache = <String, dynamic>{};
    var dirty = cachedFiles.length != fileList.length;
    for (final abs in fileList) {
      final rel = ws.relative(abs);
      final stat = FileStat.statSync(abs);
      if (stat.type == FileSystemEntityType.notFound) {
        dirty = true;
        continue;
      }
      final stamp = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
      final cached = cachedFiles[rel];
      if (cached is Map<String, dynamic> && cached['t'] == stamp) {
        files[rel] = FileOutline.fromJson(
          rel,
          cached['o'] as Map<String, dynamic>,
        );
        newCache[rel] = cached;
        continue;
      }
      dirty = true;
      String content;
      try {
        content = File(abs).readAsStringSync();
      } catch (_) {
        continue;
      }
      final outline = parseOutline(rel, content);
      files[rel] = outline;
      newCache[rel] = {'t': stamp, 'o': outline.toJson()};
    }
    if (dirty) {
      final dirs = <String, String>{};
      for (final abs in fileList) {
        final dir = abs.substring(0, abs.lastIndexOf('/'));
        dirs.putIfAbsent(dir, () => _dirStamp(dir));
      }
      try {
        Directory(ws.stateDir).createSync(recursive: true);
        final tmp = File('${cacheFile.path}.$pid.tmp');
        tmp.writeAsStringSync(
          jsonEncode({'v': _cacheVersion, 'dirs': dirs, 'files': newCache}),
        );
        tmp.renameSync(cacheFile.path);
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
      final rel = workspace.relative(
        workspace.absolute('$root/lib/${rest.substring(slash + 1)}'),
      );
      return files.containsKey(rel) ? rel : null;
    }
    final dir = fromRel.contains('/')
        ? fromRel.substring(0, fromRel.lastIndexOf('/'))
        : '';
    final rel = workspace.relative(
      workspace.absolute(dir.isEmpty ? uri : '$dir/$uri'),
    );
    return files.containsKey(rel) ? rel : null;
  }

  /// Files this file imports or exports, resolved inside the workspace.
  List<(String, UriDirective)> dependencies(String rel) {
    final f = files[rel];
    if (f == null) return const [];
    return [
      for (final d in f.directives)
        if (d.kind == 'import' || d.kind == 'export')
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

  /// Number of files other than [exceptFile] whose tokens mention [name].
  int mentions(String name, {String? exceptFile}) {
    var n = 0;
    for (final f in files.values) {
      if (f.path != exceptFile && f.identifiers.contains(name)) n++;
    }
    return n;
  }
}

String _dirStamp(String dir) {
  final s = FileStat.statSync(dir);
  return s.type == FileSystemEntityType.notFound
      ? 'missing'
      : '${s.modified.microsecondsSinceEpoch}';
}
