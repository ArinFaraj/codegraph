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

/// Asks [worker] to stop, kills it when it cannot be reached, and waits for
/// its process to end.
Future<void> stopWorker(WorkerRecord worker) async {
  final answered = await _send(
    worker,
    WorkerCall.stop,
    connectTimeout: const Duration(seconds: 1),
  );
  if (answered == null) Process.killPid(worker.pid);
  for (var i = 0; i < 50 && processAlive(worker.pid); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// This checkout's worker when its process is alive and runs this codegraph
/// version. A worker of another version is stopped, so a new one can start.
Future<WorkerRecord?> _current(Workspace ws) async {
  final w = Registry.entry(ws.root);
  if (w == null) return null;
  if (w.version != codegraphVersion) {
    await stopWorker(w);
    return null;
  }
  return processAlive(w.pid) ? w : null;
}

/// The worker for [ws] when one at this version has finished warming up;
/// never starts or stops one.
Future<WorkerRecord?> readyWorker(Workspace ws) async {
  final w = Registry.entry(ws.root);
  if (w == null || w.version != codegraphVersion) return null;
  final status = await workerStatus(
    w,
    connect: const Duration(milliseconds: 300),
    reply: const Duration(milliseconds: 500),
  );
  return status != null && status.ready && status.version == codegraphVersion
      ? w
      : null;
}

/// A running worker for [ws] at this version, starting one if needed. Null
/// when none answered within [wait].
Future<WorkerRecord?> ensureWorker(
  Workspace ws, {
  Duration wait = const Duration(seconds: 60),
}) async {
  if (await _current(ws) case final w?) {
    if (await workerStatus(w) != null) return w;
  }
  await _spawn(ws);
  final deadline = DateTime.now().add(wait);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final w = Registry.entry(ws.root);
    if (w == null || w.version != codegraphVersion) continue;
    if (await workerStatus(w) != null) return w;
  }
  return null;
}

/// Starts a worker for [ws] in the background unless one at this version is
/// alive. Does not wait for it.
Future<void> startWorker(Workspace ws) async {
  if (await _current(ws) != null) return;
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
