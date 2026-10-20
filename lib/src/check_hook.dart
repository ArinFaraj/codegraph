// `check --hook`: run after every tool call a coding agent makes. It reads
// the hook's JSON on stdin, asks the worker what the call's writes broke, and
// stays silent unless something new did. It never starts a long wait: a hook
// that blocks or nags costs more than the problems it reports.
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

Future<int> checkHook(Workspace ws, {Stream<List<int>>? input}) async {
  try {
    final raw = await utf8.decodeStream(input ?? stdin);
    final request = hookRequest(jsonDecode(raw), DateTime.now());
    if (request == null || ws.unresolvableReason != null) return Exit.ok;
    final response = await _send(ws, request).timeout(_budget);
    if (response == null || response['exit'] != Exit.failed) return Exit.ok;
    stderr.writeln(response['out']);
    return _report;
  } catch (_) {
    return Exit.ok;
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

Future<Map<String, dynamic>?> _send(Workspace ws, CheckRequest request) async {
  final state = await ensureWorker(ws, wait: const Duration(seconds: 5));
  if (state == null) return null;
  return sendToWorker(state, {'type': 'run', 'request': request.toJson()});
}
