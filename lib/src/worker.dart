// The resident analyzer for one checkout. Started on demand by the client,
// it holds the analysis contexts warm, syncs with the disk before every
// request, and exits after a quiet period so its memory comes back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'cli.dart';
import 'engine.dart';
import 'registry.dart';
import 'result.dart';
import 'version.dart';
import 'workspace.dart';

class WorkerState {
  WorkerState(this.pid, this.port, this.version);

  static WorkerState? read(Workspace ws) {
    final f = File(statePath(ws));
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
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

Duration _idleTimeout() {
  final minutes = int.tryParse(
    Platform.environment['CODEGRAPH_IDLE_MINUTES'] ?? '',
  );
  return Duration(minutes: minutes ?? 20);
}

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

  final lockFile = File(
    '${ws.stateDir}/worker.lock',
  ).openSync(mode: FileMode.write);
  try {
    lockFile.lockSync(FileLock.exclusive);
  } on FileSystemException {
    say('another worker holds the lock; exiting');
    await log.close();
    return 0;
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final stateFile = File(WorkerState.statePath(ws));
  final tmp = File('${stateFile.path}.$pid.tmp')
    ..writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'port': server.port,
        'version': codegraphVersion,
        'root': ws.root,
        'started': DateTime.now().toIso8601String(),
      }),
    );
  tmp.renameSync(stateFile.path);
  await Registry.register(ws.root, pid, server.port);
  say('worker $codegraphVersion pid $pid port ${server.port} for ${ws.root}');

  final fineDeps = Platform.environment['CODEGRAPH_FINE_DEPS'] == '1';
  Analysis.pruneByteStores();
  final started = DateTime.now();
  var phase = 'starting the analyzer';
  Analysis? analysis;
  Object? openError;

  Future<Analysis> open() async {
    phase = 'starting the analyzer';
    final a = await Analysis.open(ws, fineDeps: fineDeps);
    phase = 'indexing workspace';
    unawaited(
      a.warmUp(progress: (m) => phase = m).then((_) {
        phase = 'ready';
        say(
          'warm: ${a.fileCount} files in ${DateTime.now().difference(started).inSeconds}s',
        );
      }),
    );
    return a;
  }

  Future<Analysis?> start() => open().then<Analysis?>(
    (a) => analysis = a,
    onError: (Object e) {
      openError = e;
      say('analyzer failed to start: $e');
      return null;
    },
  );

  var opening = start();

  final done = Completer<void>();
  Timer? idle;
  void resetIdle() {
    idle?.cancel();
    idle = Timer(_idleTimeout(), () {
      say('idle; exiting');
      if (!done.isCompleted) done.complete();
    });
  }

  resetIdle();
  var queue = Future<void>.value();

  Future<void> handle(Socket socket, Map<String, dynamic> request) async {
    void send(Map<String, Object?> m) {
      try {
        socket.writeln(jsonEncode(m));
      } catch (_) {}
    }

    final type = request['type'];
    if (type == 'ping') {
      send({'ok': true, 'version': codegraphVersion});
      return;
    }
    if (type == 'stop') {
      send({'ok': true});
      if (!done.isCompleted) done.complete();
      return;
    }
    if (type == 'status') {
      final a = analysis;
      send({
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
        'idleMinutes': _idleTimeout().inMinutes,
        if (openError != null) 'error': '$openError',
      });
      return;
    }

    final argv = (request['argv'] as List).cast<String>();
    Registry.touch(ws.root);
    Timer? ticker;
    if (analysis == null) {
      send({'progress': 'waiting for the analyzer: $phase'});
      ticker = Timer.periodic(
        const Duration(seconds: 5),
        (_) => send({'progress': 'waiting for the analyzer: $phase'}),
      );
    }
    try {
      await opening;
      if (analysis == null) {
        send({
          'exit': Exit.cannotAnalyze,
          'out': 'the analyzer failed to start: $openError',
        });
        return;
      }
      if (analysis!.configChanged) {
        send({
          'progress':
              'pubspec, analysis options or package config changed; restarting the analyzer',
        });
        await analysis!.dispose();
        analysis = null;
        opening = start();
        await opening;
        if (analysis == null) {
          send({
            'exit': Exit.cannotAnalyze,
            'out': 'the analyzer failed to restart: $openError',
          });
          return;
        }
      }
      await analysis!.sync();
      final command = Command.parse(argv);
      final engine = Engine(analysis!);
      final result = await runResolvedVerb(engine, command);
      send({
        'exit': result.exit,
        'out': result.render(asJson: command.json, limit: command.limit),
      });
    } catch (e, st) {
      say('request ${argv.join(' ')} failed: $e\n$st');
      send({'exit': Exit.failed, 'out': 'codegraph worker error: $e'});
    } finally {
      ticker?.cancel();
    }
  }

  server.listen((socket) {
    resetIdle();
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final Map<String, dynamic> request;
          try {
            request = jsonDecode(line) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          final type = request['type'];
          if (type == 'ping' || type == 'status' || type == 'stop') {
            unawaited(handle(socket, request).then((_) => socket.close()));
            return;
          }
          queue = queue
              .then((_) => handle(socket, request))
              .then((_) {
                resetIdle();
                return socket.close();
              })
              .catchError((Object _) {});
        }, onError: (Object _) {});
  });

  await done.future;
  idle?.cancel();
  await server.close();
  try {
    final state = WorkerState.read(ws);
    if (state?.pid == pid) stateFile.deleteSync();
  } catch (_) {}
  Registry.unregister(ws.root);
  try {
    await analysis?.dispose();
  } catch (_) {}
  say('stopped');
  await log.close();
  lockFile.closeSync();
  return 0;
}
