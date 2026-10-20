// The resident analyzer for one checkout. Started on demand by the client,
// it keeps one engine warm, refreshes it from the disk before every request,
// and exits after a quiet period so its memory comes back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'byte_store.dart';
import 'check.dart';
import 'client.dart';
import 'commands.dart';
import 'engine.dart';
import 'protocol.dart';
import 'registry.dart';
import 'result.dart';
import 'version.dart';
import 'workspace.dart';

String workerLogPath(Workspace ws) => '${ws.stateDir}/worker.log';

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
    ledger ??= Ledger.load(workspace);
    phase = 'starting the analyzer';
    try {
      final analysis = await Analysis.open(workspace, fineDeps: fineDeps);
      phase = 'indexing workspace';
      final engine = Engine(analysis)..ledger = ledger;
      unawaited(
        analysis.warmUp(progress: (m) => phase = m).then((_) async {
          engine.ledger ??= await Ledger.build(engine);
          await engine.resolve('codegraphWarmUpLookup');
          phase = WorkerStatus.readyPhase;
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

  WorkerStatus status() {
    final a = _engine?.analysis;
    return WorkerStatus(
      version: codegraphVersion,
      pid: pid,
      phase: phase,
      files: a?.fileCount,
      indexed: a?.indexedCount,
      fineDeps: fineDeps,
      rssMb: ProcessInfo.currentRss >> 20,
      uptimeSeconds: DateTime.now().difference(started).inSeconds,
      idleMinutes: idleTimeout().inMinutes,
      error: error?.toString(),
    );
  }

  Future<void> dispose() async {
    _engine?.ledger?.save(workspace);
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
  final logFile = File(workerLogPath(ws));
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
  for (final other in Registry.overCap(ws.root)) {
    say('stopping the least recently used worker, for ${other.root}');
    await stopWorker(other);
  }
  Registry.register(
    WorkerRecord(
      root: ws.root,
      pid: pid,
      port: server.port,
      version: codegraphVersion,
      lastUsed: DateTime.now(),
    ),
  );
  pruneByteStores();
  say('worker $codegraphVersion pid $pid port ${server.port} for ${ws.root}');

  final host = AnalyzerHost(ws, say);
  unawaited(host.ready());
  final worker = _Server(ws, host, say);
  server.listen(worker.handle);

  await worker.done;
  await server.close();
  Registry.unregister(ws.root, pid);
  await host.dispose();
  say('stopped');
  await log.close();
  lock.closeSync();
  return 0;
}

/// Answers calls one at a time, and stops when asked to or after
/// [idleTimeout] without one.
class _Server {
  _Server(this.workspace, this.host, this.say) {
    _resetIdle();
  }

  final Workspace workspace;
  final AnalyzerHost host;
  final void Function(String) say;
  final _done = Completer<void>();
  Timer? _idle;
  var _queue = Future<void>.value();

  Future<void> get done => _done.future;

  void _stop() {
    _idle?.cancel();
    if (!_done.isCompleted) _done.complete();
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout(), () {
      say('idle; exiting');
      _stop();
    });
  }

  void handle(Socket socket) {
    _resetIdle();
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
          switch (callOf(message)) {
            case null:
              socket.close();
            case WorkerCall.status:
              send(host.status().toJson());
              socket.close();
            case WorkerCall.stop:
              send({'ok': true});
              socket.close();
              _stop();
            case WorkerCall.run:
              _queue = _queue
                  .then((_) => _run(send, message))
                  .whenComplete(() {
                    _resetIdle();
                    socket.close();
                  })
                  .catchError((Object _) {});
          }
        }, onError: (Object _) {});
  }

  Future<void> _run(
    void Function(Map<String, Object?>) send,
    Map<String, dynamic> message,
  ) async {
    final command = Command.fromJson(
      message['command'] as Map<String, dynamic>,
    );
    Registry.touch(workspace.root);
    Timer? ticker;
    if (!host.isReady) {
      void progress() =>
          send(progressJson('waiting for the analyzer: ${host.phase}'));
      progress();
      ticker = Timer.periodic(const Duration(seconds: 5), (_) => progress());
    }
    try {
      final engine = await host.ready();
      if (engine == null) {
        send(
          RunReply(
            Exit.cannotAnalyze,
            'the analyzer failed to start: ${host.error}',
          ).toJson(),
        );
        return;
      }
      final answer = await workerVerbs[command.verb]!.run(engine, command);
      send(
        RunReply(
          answer.exit,
          answer.render(asJson: command.json, limit: command.limit),
        ).toJson(),
      );
    } catch (e, st) {
      say('request ${jsonEncode(message)} failed: $e\n$st');
      send(RunReply(Exit.failed, 'codegraph worker error: $e').toJson());
    } finally {
      ticker?.cancel();
    }
  }
}
