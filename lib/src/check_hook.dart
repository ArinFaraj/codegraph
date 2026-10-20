// `check --hook`: run after every tool call a coding agent makes. It reads
// the hook's JSON on stdin, asks the worker what the call's writes broke, and
// stays silent unless something new did. It never waits for a worker to
// start: a hook that blocks or nags costs more than the problems it reports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'check.dart';
import 'client.dart';
import 'result.dart';
import 'workspace.dart';

/// Exit code that makes Claude Code show stderr to the agent after a tool ran.
const _report = 2;

const _budget = Duration(seconds: 15);

/// Tools that write one file and say which.
const _fileTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

/// When the worker is not ready, the call's writes are noted in a pending
/// file, the worker is started in the background, and the hook returns at
/// once; the first call after warm-up checks the pending writes with its own.
Future<int> checkHook(Workspace ws, {Stream<List<int>>? input}) async {
  try {
    final raw = await utf8.decodeStream(input ?? stdin);
    final request = hookRequest(jsonDecode(raw), DateTime.now());
    if (request == null || ws.unresolvableReason != null) return Exit.ok;
    final state = await readyWorker(ws);
    if (state == null) {
      Pending.add(ws, request);
      await startWorker(ws);
      return Exit.ok;
    }
    final response = await sendToWorker(state, {
      'type': 'run',
      'request': Pending.takeInto(ws, request).toJson(),
    }).timeout(_budget);
    if (response == null || response['exit'] != Exit.failed) return Exit.ok;
    stderr.writeln(response['out']);
    return _report;
  } catch (_) {
    return Exit.ok;
  }
}

/// Writes that hook calls could not check yet because the worker was not
/// ready: the earliest time window and the named files.
abstract final class Pending {
  static File _file(Workspace ws) => File('${ws.stateDir}/pending-check.json');

  static void add(Workspace ws, CheckRequest request) {
    final (since, paths) = _read(ws);
    final earliest = [?since, ?request.since]..sort((a, b) => a.compareTo(b));
    final file = _file(ws);
    file.parent.createSync(recursive: true);
    File('${file.path}.$pid.tmp')
      ..writeAsStringSync(
        jsonEncode({
          'since': earliest.isEmpty
              ? null
              : earliest.first.microsecondsSinceEpoch,
          'paths': {...paths, ...request.paths}.toList(),
        }),
      )
      ..renameSync(file.path);
  }

  /// [request] widened by what is pending, which is then cleared.
  static CheckRequest takeInto(Workspace ws, CheckRequest request) {
    final (since, paths) = _read(ws);
    if (since == null && paths.isEmpty) return request;
    try {
      _file(ws).deleteSync();
    } on FileSystemException {
      return request;
    }
    final earliest = [?since, ?request.since]..sort((a, b) => a.compareTo(b));
    return CheckRequest(
      paths: {...request.paths, ...paths}.toList(),
      since: earliest.isEmpty ? null : earliest.first,
      json: request.json,
      limit: request.limit,
    );
  }

  static (DateTime?, List<String>) _read(Workspace ws) {
    try {
      final j =
          jsonDecode(_file(ws).readAsStringSync()) as Map<String, dynamic>;
      final since = j['since'] as int?;
      return (
        since == null ? null : DateTime.fromMicrosecondsSinceEpoch(since),
        (j['paths'] as List).cast<String>(),
      );
    } catch (_) {
      return (null, const []);
    }
  }
}

/// The check a hook call asks for, or null when the tool cannot have written
/// anything codegraph checks.
CheckRequest? hookRequest(Object? hook, DateTime now) {
  if (hook is! Map) return null;
  final tool = hook['tool_name'];
  if (_fileTools.contains(tool)) {
    final input = hook['tool_input'];
    final path = input is Map
        ? input['file_path'] ?? input['notebook_path']
        : null;
    if (path is! String || !_checked(path)) return null;
    return CheckRequest(paths: [path], json: false, limit: 30);
  }
  if (tool == 'Bash') {
    final ran = hook['duration_ms'];
    final window = Duration(
      milliseconds: (ran is num ? ran.toInt() : 10000) + 2000,
    );
    return CheckRequest(since: now.subtract(window), json: false, limit: 30);
  }
  return null;
}

bool _checked(String path) =>
    path.endsWith('.dart') ||
    path.endsWith('/pubspec.yaml') ||
    path.endsWith('/analysis_options.yaml');
