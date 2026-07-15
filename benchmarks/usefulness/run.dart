// Usefulness benchmark: codegraph vs grep on everyday agent tasks.
//
// Run:            `dart run benchmarks/usefulness/run.dart`
// CI gate:        `dart run benchmarks/usefulness/run.dart --check`
//                 (fails on any codegraph recall/precision drop below the
//                 committed floors in baseline.json, or structuralOk=false)
// Update floors:  `dart run benchmarks/usefulness/run.dart --write-baseline`
//                 (only after a DELIBERATE change; say why in the commit)
//
// Compares recall/precision/F1, tool-call budget, and output size for each
// scenario on the shared test fixture (test/fixture.dart).

import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/model.dart';

import '../../test/fixture.dart';
import 'codegraph_arm.dart';
import 'grep_baseline.dart';
import 'scenarios.dart';

String _repoRoot() {
  final script = File(Platform.script.toFilePath());
  return script.parent.parent.parent.path;
}

String _compileCliSnapshot() {
  final out =
      '${Directory.systemTemp.createTempSync('codegraph_usefulness_').path}/cli.dill';
  final root = _repoRoot();
  final result = Process.runSync(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    '$root/bin/codegraph.dart',
    '-o',
    out,
  ]);
  if (result.exitCode != 0) {
    throw StateError('failed to compile CLI: ${result.stderr}');
  }
  return out;
}

Map<String, dynamic> runUsefulnessBenchmark() {
  if (!GrepBaseline.available) {
    stderr.writeln('warning: ripgrep (rg) not found - grep arm will be empty');
  }

  final tempDir = Directory.systemTemp.createTempSync('codegraph_usefulness_');
  final originalCwd = Directory.current;
  final cliSnapshot = _compileCliSnapshot();

  try {
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;
    engine.build(const []);
    final graph = Graph.load()!;
    final cg = CodegraphArm(tempDir, cliSnapshot);
    final grep = GrepBaseline(tempDir);

    final results = <Map<String, dynamic>>[];
    for (final scenario in usefulnessScenarios) {
      results.add(scenario.evaluate(graph: graph, cg: cg, grep: grep));
    }

    double avg(String arm, String metric) {
      final vals = results.map((r) => (r[arm] as Map)[metric] as num).toList();
      return vals.isEmpty
          ? 0
          : (vals.reduce((a, b) => a + b) / vals.length * 1000).round() / 1000;
    }

    final cgWins =
        results.where((r) => (r['winner'] as String).startsWith('codegraph'));
    final grepWins = results.where((r) => r['winner'] == 'grep');

    return {
      'generated': DateTime.now().toUtc().toIso8601String(),
      'fixture': 'test/fixture.dart',
      'scenarios': results.length,
      'summary': {
        'codegraphAvgF1': avg('codegraph', 'f1'),
        'grepAvgF1': avg('grep', 'f1'),
        'codegraphAvgRecall': avg('codegraph', 'recall'),
        'grepAvgRecall': avg('grep', 'recall'),
        'codegraphAvgPrecision': avg('codegraph', 'precision'),
        'grepAvgPrecision': avg('grep', 'precision'),
        'codegraphWins': cgWins.length,
        'grepWins': grepWins.length,
        'ties': results.length - cgWins.length - grepWins.length,
      },
      'results': results,
    };
  } finally {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  }
}

void _printTable(Map<String, dynamic> report) {
  final results = (report['results'] as List).cast<Map<String, dynamic>>();
  stdout.writeln('');
  stdout.writeln(
      'USEFULNESS BENCHMARK (${report['scenarios']} scenarios, fixture=${report['fixture']})');
  stdout.writeln(
      '${'Scenario'.padRight(28)} ${'CG F1'.padLeft(6)} ${'rg F1'.padLeft(6)} ${'CG tools'.padRight(8)} ${'rg tools'.padRight(8)} Winner');
  stdout.writeln(
      '${'-' * 28} ${'-' * 6} ${'-' * 6} ${'-' * 8} ${'-' * 8} ${'-' * 12}');
  for (final r in results) {
    final cg = r['codegraph'] as Map;
    final grep = r['grep'] as Map;
    stdout.writeln(
      '${(r['id'] as String).padRight(28)} '
      '${(cg['f1'] as num).toStringAsFixed(2).padLeft(6)} '
      '${(grep['f1'] as num).toStringAsFixed(2).padLeft(6)} '
      '${'${cg['toolCalls']}'.padRight(8)} '
      '${'${grep['toolCalls']}'.padRight(8)} '
      '${r['winner']}',
    );
  }
  final s = report['summary'] as Map;
  stdout.writeln('');
  stdout.writeln(
    'Averages: codegraph F1=${s['codegraphAvgF1']} recall=${s['codegraphAvgRecall']} '
    'precision=${s['codegraphAvgPrecision']}',
  );
  stdout.writeln(
    '          grep      F1=${s['grepAvgF1']} recall=${s['grepAvgRecall']} '
    'precision=${s['grepAvgPrecision']}',
  );
  stdout.writeln(
    'Wins: codegraph=${s['codegraphWins']} grep=${s['grepWins']} tie/other=${s['ties']}',
  );
}

String get _baselinePath =>
    '${_repoRoot()}/benchmarks/usefulness/baseline.json';

Map<String, dynamic> _floors(Map<String, dynamic> report) => {
      for (final r in (report['results'] as List).cast<Map<String, dynamic>>())
        r['id'] as String: {
          'recall': (r['codegraph'] as Map)['recall'],
          'precision': (r['codegraph'] as Map)['precision'],
          if (r.containsKey('structuralOk')) 'structuralOk': r['structuralOk'],
        },
    };

/// Compares this run's codegraph recall/precision against the committed
/// per-scenario floors. Any drop is a regression: exit 1, loudly.
int _check(Map<String, dynamic> report) {
  final f = File(_baselinePath);
  if (!f.existsSync()) {
    stderr.writeln('no baseline at $_baselinePath - run --write-baseline');
    return 1;
  }
  final floors = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final current = _floors(report);
  final failures = <String>[];
  floors.forEach((id, v) {
    final floor = v as Map<String, dynamic>;
    final now = current[id] as Map<String, dynamic>?;
    if (now == null) {
      failures.add('$id: scenario missing from run (removed without '
          'updating baseline?)');
      return;
    }
    for (final m in ['recall', 'precision']) {
      final was = (floor[m] as num).toDouble();
      final is_ = (now[m] as num).toDouble();
      if (is_ < was - 1e-9) failures.add('$id: $m $was -> $is_');
    }
    if (floor['structuralOk'] == true && now['structuralOk'] != true) {
      failures.add('$id: structuralOk went false');
    }
  });
  if (failures.isEmpty) {
    stdout.writeln('usefulness check OK (${floors.length} scenario floors)');
    return 0;
  }
  stderr.writeln('USEFULNESS REGRESSION:');
  for (final f in failures) {
    stderr.writeln('  $f');
  }
  return 1;
}

void main(List<String> args) {
  final report = runUsefulnessBenchmark();
  final json = const JsonEncoder.withIndent('  ').convert(report);

  if (args.contains('--write-baseline')) {
    File(_baselinePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_floors(report)));
    stdout.writeln('wrote $_baselinePath');
    return;
  }
  if (args.contains('--check')) {
    exit(_check(report));
  }

  if (args.contains('--json')) {
    stdout.writeln(json);
  } else {
    _printTable(report);
    stdout.writeln('');
    stdout
        .writeln('(full JSON: dart run benchmarks/usefulness/run.dart --json)');
  }

  final outPath = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : 'benchmarks/usefulness/results/latest.json';
  if (!args.contains('--no-write')) {
    final f = File('${_repoRoot()}/$outPath');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(json);
    stderr.writeln('wrote ${f.path}');
  }
}
