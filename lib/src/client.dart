// The client side of a worker: find this checkout's worker, start or stop
// it, and send it calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'registry.dart';
import 'request.dart';
import 'version.dart';
import 'workspace.dart';

/// Sends one call and returns the worker's final line. Progress lines go to
/// [onProgress]. Null when the worker cannot be reached or closes without
/// answering.
Future<Map<String, dynamic>?> _send(
  WorkerRecord worker,
  WorkerCall call, {
  WorkerRequest? request,
  void Function(String)? onProgress,
  Duration connectTimeout = const Duration(seconds: 2),
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      worker.port,
      timeout: connectTimeout,
    );
  } catch (_) {
    return null;
  }
  socket.writeln(jsonEncode(callJson(call, request)));
  await socket.flush();
  Map<String, dynamic>? last;
  await for (final line
      in socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (m['progress'] case final String p) {
      onProgress?.call(p);
      continue;
    }
    last = m;
  }
  socket.destroy();
  return last;
}

/// What [worker] says about itself. A worker still opening the analyzer can
/// be too busy to answer within [reply]; without one, this waits.
Future<WorkerStatus?> workerStatus(
  WorkerRecord worker, {
  Duration connect = const Duration(milliseconds: 500),
  Duration? reply,
}) async {
  final sent = _send(worker, WorkerCall.status, connectTimeout: connect);
  final j = reply == null
      ? await sent
      : await sent.timeout(reply, onTimeout: () => null);
  try {
    return j == null ? null : WorkerStatus.fromJson(j);
  } catch (_) {
    return null;
  }
}

/// Runs [request] on [worker]. Null when the worker stopped before answering.
Future<RunReply?> runOnWorker(
  WorkerRecord worker,
  WorkerRequest request, {
  void Function(String)? onProgress,
}) async {
  final j = await _send(
    worker,
    WorkerCall.run,
    request: request,
    onProgress: onProgress,
  );
  return j == null ? null : RunReply.fromJson(j);
}

/// Asks [worker] to stop and waits for its process to end. A worker that
/// cannot be reached serves no one, so its record is dropped instead; it is
/// never killed by pid, because a dead worker's pid may belong to another
/// program by now.
Future<void> stopWorker(WorkerRecord worker) async {
  final answered = await _send(
    worker,
    WorkerCall.stop,
    connectTimeout: const Duration(seconds: 1),
  ).timeout(const Duration(seconds: 5), onTimeout: () => null);
  if (answered == null) {
    Registry.unregister(worker.root, worker.pid);
    return;
  }
  for (var i = 0; i < 50 && processAlive(worker.pid); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// How far a caller needs a worker to be along.
enum WorkerNeed {
  /// Its process exists. Asking a starting worker more can stall: it does not
  /// answer while it opens the analyzer.
  alive,

  /// It answers calls, waiting for it to if it is busy.
  answering,

  /// It has finished warming up.
  ready,
}

/// This checkout's worker at this codegraph version, when it meets [need].
/// A worker of another version is stopped, and the record of a dead one
/// dropped, so a new worker can take their place.
Future<WorkerRecord?> workerFor(Workspace ws, WorkerNeed need) async {
  final w = Registry.entry(ws.root);
  if (w == null) return null;
  if (w.version != codegraphVersion) {
    await stopWorker(w);
    return null;
  }
  if (!processAlive(w.pid)) {
    Registry.unregister(w.root, w.pid);
    return null;
  }
  final usable = switch (need) {
    WorkerNeed.alive => true,
    WorkerNeed.answering => await workerStatus(w) != null,
    WorkerNeed.ready =>
      (await workerStatus(
            w,
            connect: const Duration(milliseconds: 300),
            reply: const Duration(milliseconds: 500),
          ))?.ready ??
          false,
  };
  return usable ? w : null;
}

/// The worker for [ws] when it has finished warming up; never starts one.
Future<WorkerRecord?> readyWorker(Workspace ws) =>
    workerFor(ws, WorkerNeed.ready);

/// A running worker for [ws] at this version, starting one if needed. Null
/// when none answered within [wait].
Future<WorkerRecord?> ensureWorker(
  Workspace ws, {
  Duration wait = const Duration(seconds: 60),
}) async {
  if (await workerFor(ws, WorkerNeed.answering) case final w?) return w;
  await _spawn(ws);
  final deadline = DateTime.now().add(wait);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (await workerFor(ws, WorkerNeed.answering) case final w?) return w;
  }
  return null;
}

/// Starts a worker for [ws] in the background unless one is alive. Does not
/// wait for it.
Future<void> startWorker(Workspace ws) async {
  if (await workerFor(ws, WorkerNeed.alive) != null) return;
  await _spawn(ws);
}

Future<void> _spawn(Workspace ws) async {
  Directory(ws.stateDir).createSync(recursive: true);
  final exe = Platform.resolvedExecutable;
  final name = Uri.file(exe).pathSegments.last;
  final isVm = name == 'dart' || name == 'dart.exe' || name == 'dartvm';
  final args = isVm
      ? [
          ...Platform.executableArguments,
          Platform.script.toFilePath(),
          '__worker',
          ws.root,
        ]
      : ['__worker', ws.root];
  await Process.start(
    isVm ? Platform.executable : exe,
    args,
    mode: ProcessStartMode.detached,
    workingDirectory: ws.root,
  );
}
