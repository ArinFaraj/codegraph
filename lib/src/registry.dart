// Machine-wide record of running workers, one file per checkout. It is the
// only record of a worker: how to reach it, which version it runs, and when it
// was last used, so parallel checkouts cannot pile up resident analyzers.
import 'dart:convert';
import 'dart:io';

/// A running worker.
class WorkerRecord {
  WorkerRecord({
    required this.root,
    required this.pid,
    required this.port,
    required this.version,
    required this.lastUsed,
  });

  /// A record written before records carried a version reads as
  /// [unknownVersion], so the worker it names is replaced, not trusted.
  factory WorkerRecord.fromJson(Map<String, dynamic> j) => WorkerRecord(
    root: j['root'] as String,
    pid: j['pid'] as int,
    port: j['port'] as int,
    version: j['version'] as String? ?? unknownVersion,
    lastUsed: DateTime.parse(j['lastUsed'] as String),
  );

  static const unknownVersion = 'unknown';

  final String root;
  final int pid;
  final int port;
  final String version;
  final DateTime lastUsed;

  Map<String, Object?> toJson() => {
    'root': root,
    'pid': pid,
    'port': port,
    'version': version,
    'lastUsed': lastUsed.toIso8601String(),
  };
}

abstract final class Registry {
  static String get _dir {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Platform.environment['CODEGRAPH_REGISTRY'] ??
        '$home/.cache/codegraph/workers';
  }

  static int get cap =>
      int.tryParse(Platform.environment['CODEGRAPH_MAX_WORKERS'] ?? '') ?? 2;

  static File _file(String root) =>
      File('$_dir/${root.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.json');

  /// The worker recorded for [root], alive or not.
  static WorkerRecord? entry(String root) => _read(_file(root));

  /// Live workers for other checkouts that must stop before one more for
  /// [root] fits under [cap], least recently used first.
  static List<WorkerRecord> overCap(String root) {
    final others = entries().where((e) => e.root != root).toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    final excess = others.length - cap + 1;
    return excess > 0 ? others.take(excess).toList() : const [];
  }

  static void register(WorkerRecord record) {
    Directory(_dir).createSync(recursive: true);
    final f = _file(record.root);
    File('${f.path}.${record.pid}.tmp')
      ..writeAsStringSync(jsonEncode(record.toJson()))
      ..renameSync(f.path);
  }

  static void touch(String root) {
    final e = entry(root);
    if (e == null) return;
    register(
      WorkerRecord(
        root: e.root,
        pid: e.pid,
        port: e.port,
        version: e.version,
        lastUsed: DateTime.now(),
      ),
    );
  }

  /// Removes the record for [root] when it still names [pid].
  static void unregister(String root, int pid) {
    if (entry(root)?.pid != pid) return;
    try {
      _file(root).deleteSync();
    } on FileSystemException {
      return;
    }
  }

  /// Every live worker; records of dead ones are deleted.
  static List<WorkerRecord> entries() {
    final dir = Directory(_dir);
    if (!dir.existsSync()) return const [];
    final out = <WorkerRecord>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final e = _read(f);
      if (e != null && processAlive(e.pid)) {
        out.add(e);
      } else {
        try {
          f.deleteSync();
        } on FileSystemException {
          continue;
        }
      }
    }
    return out;
  }

  static WorkerRecord? _read(File f) {
    try {
      return WorkerRecord.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}

bool processAlive(int pid) {
  if (Platform.isWindows) return true;
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}
