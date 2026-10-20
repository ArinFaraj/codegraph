// The resident analyzer for one checkout. Started on demand by the client,
// it keeps one engine warm, refreshes it from the disk before every request,
// and exits after a quiet period so its memory comes back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'byte_store.dart';
import 'check.dart';
import 'commands.dart';
import 'engine.dart';
import 'registry.dart';
import 'result.dart';
import 'version.dart';
import 'workspace.dart';

class WorkerState {
  WorkerState(this.pid, this.port, this.version);

  static WorkerState? read(Workspace ws) {
    try {
      final j =
          jsonDecode(File(statePath(ws)).readAsStringSync())
              as Map<String, dynamic>;
      return WorkerState(
        j['pid'] as int,
        j['port'] as int,
        j['version'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  static String statePath(Workspace ws) => '${ws.stateDir}/worker.json';
  static String logPath(Workspace ws) => '${ws.stateDir}/worker.log';

  final int pid;
  final int port;
  final String version;
}

/// Owns the engine's lifecycle: start, warm-up, and a restart when a
/// pubspec, analysis options or the package config changes.
class AnalyzerHost {
  AnalyzerHost(this.workspace, this.say)
    : fineDeps = Platform.environment['CODEGRAPH_FINE_DEPS'] == '1';

  final Workspace workspace;
  final void Function(String) say;
  final bool fineDeps;
  final DateTime started = DateTime.now();

  String phase = 'starting the analyzer';
  Object? error;
  Engine? _engine;
  Future<Engine?>? _starting;

  bool get isReady => _engine != null;

  /// The engine, refreshed from the disk. Null when the analyzer cannot start.
  Future<Engine?> ready() async {
    final engine = await (_starting ??= _start());
    if (engine == null || !(await engine.refresh()).config) return engine;
    say('configuration changed; restarting the analyzer');
    await engine.analysis.dispose();
    _engine = null;
    return _starting = _start(ledger: engine.ledger);
  }

  Future<Engine?> _start({Ledger? ledger}) async {
    phase = 'starting the analyzer';
    try {
      final analysis = await Analysis.open(workspace, fineDeps: fineDeps);
      phase = 'indexing workspace';
      final engine = Engine(analysis)..ledger = ledger;
      unawaited(
        analysis.warmUp(progress: (m) => phase = m).then((_) async {
          engine.ledger ??= await Ledger.build(engine);
          phase = 'ready';
          say(
            'warm: ${analysis.fileCount} files in '
            '${DateTime.now().difference(started).inSeconds}s',
          );
        }),
      );
      return _engine = engine;
    } catch (e) {
      error = e;
      phase = 'failed';
      say('analyzer failed to start: $e');
      return null;
    }
  }

  Map<String, Object?> status() {
    final a = _engine?.analysis;
    return {
      'ok': true,
      'version': codegraphVersion,
      'pid': pid,
      'phase': phase,
      'files': a?.fileCount,
      'indexed': a?.indexedCount,
      'warm': a?.warm ?? false,
      'contexts': a?.contextCount,
      'fineDeps': fineDeps,
      'rssMb': ProcessInfo.currentRss >> 20,
      'uptimeSeconds': DateTime.now().difference(started).inSeconds,
      'idleMinutes': idleTimeout().inMinutes,
      'error': ?error?.toString(),
    };
  }

  Future<void> dispose() async {
    try {
      await _engine?.analysis.dispose();
    } catch (_) {}
  }
}

Duration idleTimeout() => Duration(
  minutes:
      int.tryParse(Platform.environment['CODEGRAPH_IDLE_MINUTES'] ?? '') ?? 20,
);

Future<int> runWorker(String root) async {
  final ws = Workspace.find(root);
  if (ws == null) return Exit.cannotAnalyze;
  Directory(ws.stateDir).createSync(recursive: true);
  final logFile = File(WorkerState.logPath(ws));
  if (logFile.existsSync() && logFile.lengthSync() > 1 << 20) {
    logFile.renameSync('${logFile.path}.old');
  }
  final log = logFile.openWrite(mode: FileMode.append);
  void say(String m) => log.writeln('${DateTime.now().toIso8601String()} $m');

  final lock = File(
    '${ws.stateDir}/worker.lock',
  ).openSync(mode: FileMode.write);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException {
    say('another worker holds the lock; exiting');
    await log.close();
    return 0;
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final stateFile = File(WorkerState.statePath(ws));
  File('${stateFile.path}.$pid.tmp')
    ..writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'port': server.port,
        'version': codegraphVersion,
        'root': ws.root,
        'started': DateTime.now().toIso8601String(),
      }),
    )
    ..renameSync(stateFile.path);
  await Registry.register(ws.root, pid, server.port);
  pruneByteStores();
  say('worker $codegraphVersion pid $pid port ${server.port} for ${ws.root}');

  final host = AnalyzerHost(ws, say);
  unawaited(host.ready());

  final done = Completer<void>();
  void stop() {
    if (!done.isCompleted) done.complete();
  }

  Timer? idle;
  void resetIdle() {
    idle?.cancel();
    idle = Timer(idleTimeout(), () {
      say('idle; exiting');
      stop();
    });
  }

  resetIdle();
  var queue = Future<void>.value();

  Future<void> run(
    void Function(Map<String, Object?>) send,
    Map<String, dynamic> message,
  ) async {
    final request = decodeRequest(message['request'] as Map<String, dynamic>);
    Registry.touch(ws.root);
    Timer? ticker;
    if (!host.isReady) {
      void progress() =>
          send({'progress': 'waiting for the analyzer: ${host.phase}'});
      progress();
      ticker = Timer.periodic(const Duration(seconds: 5), (_) => progress());
    }
    try {
      final engine = await host.ready();
      if (engine == null) {
        send({
          'exit': Exit.cannotAnalyze,
          'out': 'the analyzer failed to start: ${host.error}',
        });
        return;
      }
      final answer = await request.run(engine);
      send({
        'exit': answer.exit,
        'out': answer.render(asJson: request.json, limit: request.limit),
      });
    } catch (e, st) {
      say('request ${jsonEncode(message)} failed: $e\n$st');
      send({'exit': Exit.failed, 'out': 'codegraph worker error: $e'});
    } finally {
      ticker?.cancel();
    }
  }

  server.listen((socket) {
    resetIdle();
    void send(Map<String, Object?> m) {
      try {
        socket.writeln(jsonEncode(m));
      } catch (_) {}
    }

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final Map<String, dynamic> message;
          try {
            message = jsonDecode(line) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          switch (message['type']) {
            case 'ping':
              send({'ok': true, 'version': codegraphVersion});
              socket.close();
            case 'status':
              send(host.status());
              socket.close();
            case 'stop':
              send({'ok': true});
              socket.close();
              stop();
            case 'run':
              queue = queue
                  .then((_) => run(send, message))
                  .whenComplete(() {
                    resetIdle();
                    socket.close();
                  })
                  .catchError((Object _) {});
          }
        }, onError: (Object _) {});
  });

  await done.future;
  idle?.cancel();
  await server.close();
  if (WorkerState.read(ws)?.pid == pid) {
    try {
      stateFile.deleteSync();
    } catch (_) {}
  }
  Registry.unregister(ws.root);
  await host.dispose();
  say('stopped');
  await log.close();
  lock.closeSync();
  return 0;
}
