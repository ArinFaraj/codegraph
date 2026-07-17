// Stage A agent-impact benchmark runner: two otherwise identical agent arms,
// with and without codegraph, on the frozen task set in tasks.dart.
//
//   dart run benchmarks/agent_impact/runner.dart \
//     --agent devin            # or: claude, or --agent-cmd '<template>'
//     [--arm both|baseline|codegraph] [--tasks id,id] [--runs 3]
//     [--timeout-sec 900] [--keep] [--out results/<file>.jsonl]
//
// Arms differ ONLY in environment, never in prompt:
//   baseline  - the workspace, plus a PATH shim that makes `codegraph` exit
//               127 (this machine has a global install; the shim keeps the
//               baseline arm honest).
//   codegraph - the same workspace after `codegraph init` + `codegraph build`
//               (run from THIS repo's source via a compiled snapshot, so the
//               benchmark measures current code), with the CLAUDE.md block
//               copied to AGENTS.md so non-Claude agents see it too.
//
// Scoring is code-computed (benchmarks honesty rules): oracle regexes + git
// cleanliness + `dart analyze` + `dart run test/all_tests.dart`. Wall time is
// always recorded; agent tokens/steps are parsed best-effort from the agent
// CLI's export when the preset supports it (devin).
import 'dart:convert';
import 'dart:io';

import 'tasks.dart';
import 'workspace.dart';

void main(List<String> args) async {
  String? flag(String name) {
    final i = args.indexOf('--$name');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  final agentPreset = flag('agent') ?? 'devin';
  final agentCmdTemplate = flag('agent-cmd');
  final armArg = flag('arm') ?? 'both';
  final runs = int.tryParse(flag('runs') ?? '1') ?? 1;
  final timeoutSec = int.tryParse(flag('timeout-sec') ?? '900') ?? 900;
  final keep = args.contains('--keep');
  final taskFilter = flag('tasks')?.split(',').toSet();

  final repoRoot = Directory.current;
  if (!File('${repoRoot.path}/bin/codegraph.dart').existsSync()) {
    stderr.writeln('run from the codegraph repo root');
    exit(64);
  }

  final tasks = benchTasks
      .where((t) => taskFilter == null || taskFilter.contains(t.id))
      .toList();
  if (tasks.isEmpty) {
    stderr.writeln('no tasks match --tasks $taskFilter '
        '(known: ${benchTasks.map((t) => t.id).join(', ')})');
    exit(64);
  }
  final arms = switch (armArg) {
    'both' => ['baseline', 'codegraph'],
    'baseline' || 'codegraph' => [armArg],
    _ => null,
  };
  if (arms == null) {
    stderr.writeln('--arm must be both|baseline|codegraph');
    exit(64);
  }

  final outPath = flag('out') ??
      'benchmarks/agent_impact/results/'
          '${DateTime.now().toIso8601String().replaceAll(':', '-')}.jsonl';
  File(outPath).parent.createSync(recursive: true);

  // Compile the CURRENT repo's codegraph once; both shim scripts live in one
  // dir prepended to PATH per arm.
  final work = Directory.systemTemp.createTempSync('agent_impact_');
  final snapshot = '${work.path}/codegraph.dill';
  final compiled = Process.runSync(
      'dart', ['compile', 'kernel', 'bin/codegraph.dart', '-o', snapshot]);
  if (compiled.exitCode != 0) {
    stderr.writeln('failed to compile codegraph: ${compiled.stderr}');
    exit(70);
  }
  final realBin = Directory('${work.path}/bin_real')..createSync();
  final blockBin = Directory('${work.path}/bin_block')..createSync();
  _writeExec(
      '${realBin.path}/codegraph', '#!/bin/sh\nexec dart "$snapshot" "\$@"\n');
  _writeExec('${blockBin.path}/codegraph',
      '#!/bin/sh\necho "codegraph: command not found" >&2\nexit 127\n');

  final results = <Map<String, dynamic>>[];
  var attempt = 0;
  final total = tasks.length * arms.length * runs;
  for (var run = 0; run < runs; run++) {
    for (final task in tasks) {
      // Alternate arm order per run to cancel ordering effects.
      final ordered = run.isEven ? arms : arms.reversed.toList();
      for (final arm in ordered) {
        attempt++;
        stderr.writeln('[$attempt/$total] ${task.id} / $arm / run$run ...');
        final rec = await _runAttempt(
          task: task,
          arm: arm,
          run: run,
          shimDir: arm == 'codegraph' ? realBin.path : blockBin.path,
          agentPreset: agentPreset,
          agentCmdTemplate: agentCmdTemplate,
          timeoutSec: timeoutSec,
          keep: keep,
        );
        results.add(rec);
        File(outPath)
            .writeAsStringSync('${jsonEncode(rec)}\n', mode: FileMode.append);
        stderr.writeln('    -> ${rec['success'] == true ? 'PASS' : 'FAIL'} '
            '(${rec['wallMs']}ms) ${rec['failReasons'] ?? ''}');
      }
    }
  }
  if (!keep) work.deleteSync(recursive: true);

  // Aggregate (in code, per honesty rules).
  stdout.writeln('\n=== agent impact summary ===');
  for (final arm in arms) {
    final mine = results.where((r) => r['arm'] == arm).toList();
    final byKind = <String, List<Map<String, dynamic>>>{};
    for (final r in mine) {
      byKind.putIfAbsent(r['kind'] as String, () => []).add(r);
    }
    String rate(List<Map<String, dynamic>> rs) => rs.isEmpty
        ? '-'
        : '${rs.where((r) => r['success'] == true).length}/${rs.length}';
    final ms = mine.map((r) => r['wallMs'] as int).toList()..sort();
    final median = ms.isEmpty ? 0 : ms[ms.length ~/ 2];
    stdout.writeln('$arm: overall ${rate(mine)}  '
        'edit ${rate(byKind['edit'] ?? [])}  '
        'refusal ${rate(byKind['refusal'] ?? [])}  '
        'median ${median}ms');
  }
  stdout.writeln('raw results: $outPath');
}

Future<Map<String, dynamic>> _runAttempt({
  required BenchTask task,
  required String arm,
  required int run,
  required String shimDir,
  required String agentPreset,
  required String? agentCmdTemplate,
  required int timeoutSec,
  required bool keep,
}) async {
  final ws = Directory.systemTemp.createTempSync('aib_${task.id}_${arm}_');
  writeAgentBenchWorkspace(ws);
  final env = {
    ...Platform.environment,
    'PATH': '$shimDir:${Platform.environment['PATH']}',
  };
  ProcessResult inWs(String cmd, List<String> a) =>
      Process.runSync(cmd, a, workingDirectory: ws.path, environment: env);

  if (arm == 'codegraph') {
    // Equip the workspace with the real product surface, then snapshot it as
    // the git baseline so tool scaffolding never counts as an agent edit.
    // A silent setup failure would corrupt the A/B (treatment would secretly
    // equal baseline) - fail the whole run loudly instead.
    for (final step in [
      ['init'],
      ['build'],
    ]) {
      final r = inWs('codegraph', step);
      if (r.exitCode != 0) {
        stderr.writeln('treatment setup failed (codegraph ${step.join(' ')}): '
            '${r.stderr}');
        exit(70);
      }
    }
    final claudeMd = File('${ws.path}/CLAUDE.md');
    if (!claudeMd.existsSync()) {
      stderr.writeln('treatment setup failed: init wrote no CLAUDE.md');
      exit(70);
    }
    File('${ws.path}/AGENTS.md').writeAsStringSync(claudeMd.readAsStringSync());
    if (!File('${ws.path}/docs/maps/code_graph.json').existsSync()) {
      stderr.writeln('treatment setup failed: build wrote no graph');
      exit(70);
    }
  }
  // Scoring is git-diff-based; a failed baseline commit would misattribute
  // pre-existing files as agent edits. Fail loudly.
  for (final step in [
    ['init', '-q'],
    ['add', '-A'],
    [
      '-c', 'user.email=bench@local', '-c', 'user.name=bench', //
      'commit', '-qm', 'baseline'
    ],
  ]) {
    final r = inWs('git', step);
    if (r.exitCode != 0) {
      stderr.writeln('workspace git ${step.first} failed: ${r.stderr}');
      exit(70);
    }
  }

  final sessionFile = '${ws.path}/.agent_session.json';
  final cmd =
      _agentCommand(agentPreset, agentCmdTemplate, task.prompt, sessionFile);

  final sw = Stopwatch()..start();
  var timedOut = false;
  String agentTail = '';
  try {
    final p = await Process.start(cmd.first, cmd.skip(1).toList(),
        workingDirectory: ws.path, environment: env);
    final outBuf = StringBuffer();
    p.stdout.transform(utf8.decoder).listen(outBuf.write);
    p.stderr.transform(utf8.decoder).listen(outBuf.write);
    final exit =
        await p.exitCode.timeout(Duration(seconds: timeoutSec), onTimeout: () {
      timedOut = true;
      p.kill(ProcessSignal.sigkill);
      return -9;
    });
    final s = outBuf.toString();
    agentTail = s.length > 2000 ? s.substring(s.length - 2000) : s;
    if (exit != 0 && !timedOut) {
      agentTail = 'exit=$exit\n$agentTail';
    }
  } catch (e) {
    agentTail = 'agent launch failed: $e';
  }
  sw.stop();

  // ---- score ----
  final failReasons = <String>[];
  final changed = changedFromPorcelain(
      inWs('git', ['status', '--porcelain']).stdout as String);

  final analyze = inWs('dart', ['analyze']);
  final tests = inWs('dart', ['run', 'test/all_tests.dart']);
  final green = analyze.exitCode == 0 && tests.exitCode == 0;
  if (analyze.exitCode != 0) failReasons.add('analysis red');
  if (tests.exitCode != 0) failReasons.add('tests red');

  if (task.kind == 'refusal') {
    if (changed.isNotEmpty) {
      failReasons.add('made changes on a must-refuse task: '
          '${changed.take(5).join(', ')}');
    }
  } else {
    final outsideScope =
        changed.where((f) => !task.allowedFiles.contains(f)).toList();
    if (outsideScope.isNotEmpty) {
      failReasons.add('unrelated edits: ${outsideScope.take(5).join(', ')}');
    }
    failReasons.addAll(evalChecks(ws, task));
  }
  if (timedOut) failReasons.add('timeout');

  final rec = <String, dynamic>{
    'task': task.id,
    'kind': task.kind,
    'arm': arm,
    'run': run,
    'success': failReasons.isEmpty && green,
    'wallMs': sw.elapsedMilliseconds,
    'timedOut': timedOut,
    'changedFiles': changed,
    if (failReasons.isNotEmpty) 'failReasons': failReasons,
    ..._agentMetrics(sessionFile),
    'agentTail': agentTail,
  };
  if (keep) {
    rec['workspace'] = ws.path;
  } else {
    ws.deleteSync(recursive: true);
  }
  return rec;
}

List<String> _agentCommand(
    String preset, String? template, String prompt, String sessionFile) {
  if (template != null) {
    return [
      for (final part in template.split(' ')) part == '{prompt}' ? prompt : part
    ];
  }
  switch (preset) {
    case 'devin':
      return [
        'devin', '--model', 'swe-1.7', '--permission-mode', 'dangerous',
        '--export', sessionFile, '-p', prompt //
      ];
    case 'claude':
      return ['claude', '--dangerously-skip-permissions', '-p', prompt];
    default:
      stderr.writeln('unknown --agent $preset (devin|claude|--agent-cmd)');
      exit(64);
  }
}

/// Best-effort tokens/steps from the agent's exported session (devin shape).
Map<String, dynamic> _agentMetrics(String sessionFile) {
  try {
    final j = jsonDecode(File(sessionFile).readAsStringSync());
    final m = (j as Map)['final_metrics'] as Map?;
    if (m == null) return const {};
    return {
      'agentSteps': m['total_steps'],
      'agentPromptTokens': m['total_prompt_tokens'],
      'agentCompletionTokens': m['total_completion_tokens'],
    };
  } catch (_) {
    return const {};
  }
}

void _writeExec(String path, String content) {
  File(path).writeAsStringSync(content);
  Process.runSync('chmod', ['+x', path]);
}
