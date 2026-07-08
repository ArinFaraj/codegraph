// Usefulness benchmark: codegraph vs grep on everyday agent tasks.
//
// Run: `dart run benchmarks/usefulness/run.dart`
// Write frozen ground truth: `dart run benchmarks/usefulness/generate_ground_truth.dart`
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
    stderr.writeln('warning: ripgrep (rg) not found — grep arm will be empty');
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

void main(List<String> args) {
  final report = runUsefulnessBenchmark();
  final json = const JsonEncoder.withIndent('  ').convert(report);

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
