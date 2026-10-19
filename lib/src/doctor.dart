import 'dart:io';

import 'analysis.dart' show analyzerLanguageVersion;
import 'client.dart';
import 'registry.dart';
import 'result.dart';
import 'sdk.dart';
import 'version.dart';
import 'worker.dart';
import 'workspace.dart';

/// Worker and setup status, or worker control with [warm], [stop] and
/// [restart]. `--warm` is for session hooks: it never prints and never fails.
Future<int> doctor(
  Workspace ws, {
  required bool warm,
  required bool stop,
  required bool restart,
}) async {
  if (stop || restart) {
    await stopWorker(ws);
    if (stop) {
      stdout.writeln('worker stopped');
      return 0;
    }
  }
  if (warm || restart) {
    if (ws.unresolvableReason != null) return warm ? 0 : Exit.cannotAnalyze;
    final state = await ensureWorker(ws, wait: const Duration(seconds: 20));
    if (restart) {
      stdout.writeln(
        state == null ? 'worker failed to start' : 'worker restarted',
      );
    }
    return 0;
  }

  final reason = ws.unresolvableReason;
  final sdkPath = sdkPathForAnalysis();
  final sdk = sdkVersion(sdkPath);
  final understood = analyzerLanguageVersion();
  final lines = [
    'codegraph $codegraphVersion',
    'workspace: ${ws.root}',
    'package config: ${reason ?? 'ok'}',
    'dart sdk: ${sdk ?? 'not found'}'
        '${sdkPath == null ? ' (the running VM)' : ' ($sdkPath)'}',
    'bundled analyzer understands Dart up to $understood',
    if (sdk != null && _newer(sdk, understood))
      'warning: the SDK is newer than the bundled analyzer; code using new '
          'language features may not resolve. Update codegraph.',
    await _workerLine(ws),
  ];
  final others = Registry.entries().where((e) => e.root != ws.root).toList();
  lines.add(
    'other workers on this machine: ${others.length} (cap ${Registry.cap})'
    '${others.isEmpty ? '' : ': ${others.map((e) => e.root).join(', ')}'}',
  );
  stdout.writeln(lines.join('\n'));
  return reason == null ? 0 : Exit.cannotAnalyze;
}

Future<String> _workerLine(Workspace ws) async {
  final state = WorkerState.read(ws);
  if (state == null) {
    return 'worker: not running (starts on the first refs, impact, rename or '
        'show <symbol>)';
  }
  final s = await sendToWorker(state, {
    'type': 'status',
  }, connectTimeout: const Duration(milliseconds: 800));
  if (s == null) {
    return 'worker: not responding (pid ${state.pid}); doctor --restart';
  }
  return 'worker: ${s['version']} pid ${s['pid']}, ${s['phase']}, '
      '${s['files']} files, ${s['indexed']} indexed, ${s['rssMb']}MB, '
      'up ${s['uptimeSeconds']}s, exits after ${s['idleMinutes']} idle minutes'
      '${s['fineDeps'] == true ? ', fine dependencies' : ''}'
      '${s['error'] != null ? ', error: ${s['error']}' : ''}';
}

bool _newer(String sdk, String languageVersion) {
  final a = sdk.split(RegExp(r'[.-]')).take(2).map(int.tryParse).toList();
  final b = languageVersion.split('.').map(int.tryParse).toList();
  if (a.length < 2 || a.contains(null) || b.contains(null)) return false;
  return a[0]! > b[0]! || (a[0] == b[0] && a[1]! > b[1]!);
}
