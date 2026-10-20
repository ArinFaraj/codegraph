// `check --hook`: run after every tool call a coding agent makes. It reads
// the hook's JSON on stdin, asks the worker what the call's writes broke, and
// stays silent unless something new did. It never waits for a worker to
// start: a hook that blocks or nags costs more than the problems it reports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'client.dart';
import 'commands.dart';
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
    final reply = await runOnWorker(
      state,
      Pending.takeInto(ws, request),
    ).timeout(_budget);
    if (reply == null || reply.exit != Exit.failed) return Exit.ok;
    stderr.writeln(reply.out);
    return _report;
  } catch (_) {
    return Exit.ok;
  }
}

/// The `check` that hook calls could not run yet because the worker was not
/// ready, kept as one command covering all of them.
abstract final class Pending {
  static File _file(Workspace ws) => File('${ws.stateDir}/pending-check.json');

  static void add(Workspace ws, Command check) {
    final file = _file(ws);
    file.parent.createSync(recursive: true);
    final merged = switch (_read(ws)) {
      final pending? => _merge(pending, check),
      null => check,
    };
    File('${file.path}.$pid.tmp')
      ..writeAsStringSync(jsonEncode(merged.toJson()))
      ..renameSync(file.path);
  }

  /// [check] widened by what is pending, which is then cleared.
  static Command takeInto(Workspace ws, Command check) {
    final pending = _read(ws);
    if (pending == null) return check;
    try {
      _file(ws).deleteSync();
    } on FileSystemException {
      return check;
    }
    return _merge(pending, check);
  }

  static Command? _read(Workspace ws) {
    try {
      return Command.fromJson(
        jsonDecode(_file(ws).readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  static Command _merge(Command a, Command b) {
    final times = [?a.since, ?b.since]..sort();
    return Command(
      'check',
      {...a.args, ...b.args}.toList(),
      limit: b.limit,
      cwd: b.cwd,
      since: times.firstOrNull,
    );
  }
}

/// The check a hook call asks for, or null when the tool cannot have written
/// anything codegraph checks.
Command? hookRequest(Object? hook, DateTime now) {
  if (hook is! Map) return null;
  final tool = hook['tool_name'];
  if (_fileTools.contains(tool)) {
    final input = hook['tool_input'];
    final path = input is Map
        ? input['file_path'] ?? input['notebook_path']
        : null;
    if (path is! String || !_checked(path)) return null;
    return Command('check', [path], limit: 30);
  }
  if (tool == 'Bash') {
    final ran = hook['duration_ms'];
    final window = Duration(
      milliseconds: (ran is num ? ran.toInt() : 10000) + 2000,
    );
    return Command('check', const [], limit: 30, since: now.subtract(window));
  }
  return null;
}

bool _checked(String path) =>
    path.endsWith('.dart') ||
    path.endsWith('/pubspec.yaml') ||
    path.endsWith('/analysis_options.yaml');
