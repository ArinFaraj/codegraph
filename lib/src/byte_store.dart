// Where the analyzer keeps its on-disk cache: one directory per checkout,
// pruned when unused for a month.
import 'dart:io';

import 'workspace.dart';

String byteStoreBase() {
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return Platform.environment['CODEGRAPH_BYTE_STORE'] ??
      '$home/.cache/codegraph/byte-store';
}

/// One cache per checkout. Entries are keyed by content, but some carry
/// paths, so a cache filled by a checkout at another path silently drops
/// references here.
String byteStoreFor(Workspace workspace) {
  var h = 0xcbf29ce484222325;
  for (final c in workspace.root.codeUnits) {
    h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return '${byteStoreBase()}/${h.toRadixString(16)}';
}

/// Creates [path] and marks it used. FileByteStore writes nothing, silently,
/// when its directory is missing.
String openByteStore(String path, Workspace workspace) {
  Directory(path).createSync(recursive: true);
  File('$path/.last-used').writeAsStringSync(workspace.root);
  return path;
}

/// Deletes per-checkout caches untouched for [age], keeping disk use bounded.
void pruneByteStores({Duration age = const Duration(days: 30)}) {
  final base = Directory(byteStoreBase());
  if (!base.existsSync()) return;
  final cutoff = DateTime.now().subtract(age);
  for (final d in base.listSync().whereType<Directory>()) {
    try {
      final marker = File('${d.path}/.last-used');
      final used = marker.existsSync()
          ? marker.lastModifiedSync()
          : d.statSync().modified;
      if (used.isBefore(cutoff)) d.deleteSync(recursive: true);
    } catch (_) {}
  }
}
