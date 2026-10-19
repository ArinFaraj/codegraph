// Machine-wide list of running workers, so parallel checkouts cannot pile up
// resident analyzers. When a new worker would exceed the cap, the least
// recently used one is asked to stop.
import 'dart:convert';
import 'dart:io';

abstract final class Registry {
  static String get _dir {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Platform.environment['CODEGRAPH_REGISTRY'] ??
        '$home/.cache/codegraph/workers';
  }

  static int get cap =>
      int.tryParse(Platform.environment['CODEGRAPH_MAX_WORKERS'] ?? '') ?? 2;

  static String _key(String root) =>
      root.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');

  static File _file(String root) => File('$_dir/${_key(root)}.json');

  static Future<void> register(String root, int pid, int port) async {
    Directory(_dir).createSync(recursive: true);
    final live = entries().where((e) => e.root != root).toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    while (live.length >= cap) {
      await _stop(live.removeAt(0));
    }
    _write(root, pid, port);
  }

  static void touch(String root) {
    final f = _file(root);
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _write(root, j['pid'] as int, j['port'] as int);
    } catch (_) {}
  }

  static void unregister(String root) {
    try {
      _file(root).deleteSync();
    } catch (_) {}
  }

  static List<RegistryEntry> entries() {
    final dir = Directory(_dir);
    if (!dir.existsSync()) return const [];
    final out = <RegistryEntry>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final e = RegistryEntry(
          j['root'] as String,
          j['pid'] as int,
          j['port'] as int,
          DateTime.parse(j['lastUsed'] as String),
        );
        if (_alive(e.pid)) {
          out.add(e);
        } else {
          f.deleteSync();
        }
      } catch (_) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    return out;
  }

  static void _write(String root, int pid, int port) {
    final f = _file(root);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(
      jsonEncode({
        'root': root,
        'pid': pid,
        'port': port,
        'lastUsed': DateTime.now().toIso8601String(),
      }),
    );
    tmp.renameSync(f.path);
  }

  static Future<void> _stop(RegistryEntry e) async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        e.port,
        timeout: const Duration(seconds: 1),
      );
      s.write('${jsonEncode({'type': 'stop'})}\n');
      await s.flush();
      await s.close();
    } catch (_) {
      Process.killPid(e.pid);
    }
    unregister(e.root);
  }

  static bool _alive(int pid) {
    if (Platform.isWindows) return true;
    final r = Process.runSync('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  }
}

class RegistryEntry {
  RegistryEntry(this.root, this.pid, this.port, this.lastUsed);
  final String root;
  final int pid;
  final int port;
  final DateTime lastUsed;
}
