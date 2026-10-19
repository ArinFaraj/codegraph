import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'version.dart';
import 'worker.dart';
import 'workspace.dart';

/// Sends one request to the worker and returns its final message. Progress
/// messages go to [onProgress].
Future<Map<String, dynamic>?> sendToWorker(
  WorkerState state,
  Map<String, Object?> request, {
  void Function(String)? onProgress,
  Duration connectTimeout = const Duration(seconds: 2),
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      state.port,
      timeout: connectTimeout,
    );
  } catch (_) {
    return null;
  }
  socket.writeln(jsonEncode(request));
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

Future<bool> ping(WorkerState state) async {
  final r = await sendToWorker(state, {
    'type': 'ping',
  }, connectTimeout: const Duration(milliseconds: 500));
  return r?['ok'] == true && r?['version'] == codegraphVersion;
}

/// A running worker for [ws] at this codegraph version, starting one if
/// needed. Null when none could be started.
Future<WorkerState?> ensureWorker(
  Workspace ws, {
  Duration wait = const Duration(seconds: 60),
}) async {
  var state = WorkerState.read(ws);
  if (state != null) {
    if (await ping(state)) return state;
    if (state.version != codegraphVersion) {
      await sendToWorker(state, {'type': 'stop'});
      await _waitForExit(state.pid);
    }
  }
  final previousPid = state?.pid;
  await _spawn(ws);
  final deadline = DateTime.now().add(wait);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state = WorkerState.read(ws);
    if (state == null) continue;
    if (state.pid == previousPid && state.version != codegraphVersion) continue;
    if (await ping(state)) return state;
  }
  return null;
}

Future<void> stopWorker(Workspace ws) async {
  final state = WorkerState.read(ws);
  if (state == null) return;
  await sendToWorker(state, {'type': 'stop'});
  await _waitForExit(state.pid);
}

Future<void> _waitForExit(int pid) async {
  for (var i = 0; i < 50; i++) {
    final r = await Process.run('kill', ['-0', '$pid']);
    if (r.exitCode != 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Test seam: the command that starts a worker, as executable + arguments
/// before `__worker <root>`.
List<String>? workerCommandOverride;

Future<void> _spawn(Workspace ws) async {
  Directory(ws.stateDir).createSync(recursive: true);
  final override = workerCommandOverride;
  if (override != null) {
    await Process.start(
      override.first,
      [...override.skip(1), '__worker', ws.root],
      mode: ProcessStartMode.detached,
      workingDirectory: ws.root,
    );
    return;
  }
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
