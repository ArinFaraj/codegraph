// What the client and a worker say to each other over a local socket: one
// JSON object per line. A call is answered by one final line; `run` sends
// progress lines before it.
import 'request.dart';

enum WorkerCall { status, stop, run }

Map<String, Object?> callJson(WorkerCall call, [WorkerRequest? request]) => {
  'type': call.name,
  if (request != null) 'request': request.toJson(),
};

WorkerCall? callOf(Map<String, dynamic> message) =>
    WorkerCall.values.asNameMap()[message['type']];

/// A worker's answer to [WorkerCall.status].
class WorkerStatus {
  WorkerStatus({
    required this.version,
    required this.pid,
    required this.phase,
    required this.files,
    required this.indexed,
    required this.fineDeps,
    required this.rssMb,
    required this.uptimeSeconds,
    required this.idleMinutes,
    this.error,
  });

  factory WorkerStatus.fromJson(Map<String, dynamic> j) => WorkerStatus(
    version: j['version'] as String,
    pid: j['pid'] as int,
    phase: j['phase'] as String,
    files: j['files'] as int?,
    indexed: j['indexed'] as int?,
    fineDeps: j['fineDeps'] as bool,
    rssMb: j['rssMb'] as int,
    uptimeSeconds: j['uptimeSeconds'] as int,
    idleMinutes: j['idleMinutes'] as int,
    error: j['error'] as String?,
  );

  static const readyPhase = 'ready';

  final String version;
  final int pid;
  final String phase;
  final int? files;
  final int? indexed;
  final bool fineDeps;
  final int rssMb;
  final int uptimeSeconds;
  final int idleMinutes;
  final String? error;

  bool get ready => phase == readyPhase;

  Map<String, Object?> toJson() => {
    'version': version,
    'pid': pid,
    'phase': phase,
    'files': files,
    'indexed': indexed,
    'fineDeps': fineDeps,
    'rssMb': rssMb,
    'uptimeSeconds': uptimeSeconds,
    'idleMinutes': idleMinutes,
    'error': ?error,
  };
}

/// A worker's final answer to [WorkerCall.run].
class RunReply {
  RunReply(this.exit, this.out);

  factory RunReply.fromJson(Map<String, dynamic> j) =>
      RunReply(j['exit'] as int, j['out'] as String? ?? '');

  final int exit;
  final String out;

  Map<String, Object?> toJson() => {'exit': exit, 'out': out};
}

Map<String, Object?> progressJson(String message) => {'progress': message};
