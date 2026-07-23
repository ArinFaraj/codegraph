// Performance benchmark for codegraph build + query verbs.
//
// Run: `dart run benchmarks/perf.dart`
// Compare: `dart run benchmarks/perf.dart --compare benchmarks/perf_baseline.json`
//
// Uses the same fixture as the test suite (test/fixture.dart). Reports median
// wall times (ms) over [iterations] after a warmup. Fails --compare when any
// metric regresses more than [regressionPct]% (default 15%) unless within
// [regressionAbsMs] absolute noise floor (default 25ms).

import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/callchain.dart' as callchain;
import 'package:codegraph/src/callers.dart' as callers;
import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/query.dart' as query;
import 'package:codegraph/src/rename.dart' as rename;

import '../test/fixture.dart';

const _iterations = 5;
const _regressionPct = 15.0;
const _regressionAbsMs = 25.0;
const _ratioReferenceMetrics = {
  'rename_analyzer_ms',
  'callers_analyzer_ms',
};

bool usesAbsoluteBaseline(String metric) =>
    !_ratioReferenceMetrics.contains(metric);

typedef _BenchFn = void Function();
typedef _AsyncBenchFn = Future<void> Function();

int _medianMs(List<int> samples) {
  final sorted = [...samples]..sort();
  return sorted[sorted.length ~/ 2];
}

int _timeMs(_BenchFn fn) {
  final sw = Stopwatch()..start();
  fn();
  sw.stop();
  return sw.elapsedMilliseconds;
}

Map<String, int> _medianBench(Map<String, _BenchFn> fns,
    {int n = _iterations}) {
  final out = <String, int>{};
  for (final e in fns.entries) {
    final samples = <int>[];
    for (var i = 0; i < n; i++) {
      samples.add(_timeMs(e.value));
    }
    out[e.key] = _medianMs(samples);
  }
  return out;
}

Future<int> _timeAsyncMs(_AsyncBenchFn fn) async {
  final sw = Stopwatch()..start();
  await fn();
  sw.stop();
  return sw.elapsedMilliseconds;
}

Future<Map<String, int>> _medianAsyncBench(Map<String, _AsyncBenchFn> fns,
    {int n = _iterations}) async {
  final out = <String, int>{};
  for (final e in fns.entries) {
    final samples = <int>[];
    for (var i = 0; i < n; i++) {
      samples.add(await _timeAsyncMs(e.value));
    }
    out[e.key] = _medianMs(samples);
  }
  return out;
}

Future<Map<String, int>> runPerfBenchmark() async {
  final tempDir = Directory.systemTemp.createTempSync('codegraph_perf_');
  final originalCwd = Directory.current;
  try {
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;

    // Warmup JIT + filesystem cache.
    engine.build(const []);
    query.run(['find', 'home']);
    query.run(['readers', 'homeProvider']);

    final buildOnly = _medianBench({
      'build_ms': () => engine.build(const []),
    });

    // Graph must exist for query benches.
    engine.build(const []);

    final queries = _medianBench({
      'find_home_ms': () => query.run(['find', 'home']),
      'sym_home_ms': () => query.run(['sym', 'HomePage']),
      'readers_homeProvider_ms': () => query.run(['readers', 'homeProvider']),
      'impls_shape_ms': () => query.run(['impls', 'Shape']),
      'callers_pingTarget_ms': () => callers.run(['callers', 'pingTarget']),
      'callchain_chainEntry_ms': () =>
          callchain.run(['callchain', 'chainEntry', '--depth', '3']),
    });

    // A production-shaped refactor fixture: unrelated same-named methods and
    // a test call site prove that the fast path is semantic, not text search.
    writeFixturePackageConfig(tempDir);
    File('lib/refactor_perf.dart').writeAsStringSync('''
class RefactorTarget {
  int calculate(int value) => value + 1;
}
class UnrelatedTarget {
  int calculate(int value) => value - 1;
}
int useTarget(RefactorTarget target) => target.calculate(1);
''');
    File('test/refactor_perf_test.dart').writeAsStringSync('''
import 'package:fixture/refactor_perf.dart';
int exercise() => RefactorTarget().calculate(2);
''');

    // Warm the analyzer and materialize the persistent resolved index.
    await engine.buildResolved(const []);
    final resolved = await _medianAsyncBench({
      'resolved_build_ms': () => engine.buildResolved(const []),
    }, n: 3);

    Future<void> checkedRename(List<String> args) async {
      final code = await rename.run(args);
      if (code != 0) throw StateError('rename benchmark refused: $code');
    }

    final indexedRename = await _medianAsyncBench({
      'rename_indexed_ms': () => checkedRename([
            'rename',
            'RefactorTarget.calculate',
            'computeValue',
            '--json',
          ]),
    });
    final analyzerRename = await _medianAsyncBench({
      'rename_analyzer_ms': () => checkedRename([
            'rename',
            'RefactorTarget.calculate',
            'computeValue',
            '--json',
            '--no-index',
          ]),
    }, n: 3);
    final indexedCallers = await _medianAsyncBench({
      'callers_indexed_ms': () async {
        final code = await callers.runResolved([
          'callers',
          'calculate',
          '--resolved',
          '--json',
        ]);
        if (code != 0) throw StateError('callers benchmark failed: $code');
      },
    });
    final analyzerCallers = await _medianAsyncBench({
      'callers_analyzer_ms': () async {
        final code = await callers.runResolved([
          'callers',
          'calculate',
          '--resolved',
          '--json',
          '--no-index',
        ]);
        if (code != 0) throw StateError('callers benchmark failed: $code');
      },
    }, n: 3);

    return {
      ...buildOnly,
      ...queries,
      ...resolved,
      ...indexedRename,
      ...analyzerRename,
      ...indexedCallers,
      ...analyzerCallers,
    };
  } finally {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  }
}

bool _regressed(int baseline, int current) {
  if (current <= baseline) return false;
  final delta = current - baseline;
  if (delta <= _regressionAbsMs) return false;
  return delta > baseline * (_regressionPct / 100.0);
}

Future<int> main(List<String> args) async {
  final writeBaseline = args.contains('--write-baseline');
  final compareFile = args.contains('--compare')
      ? File(args[args.indexOf('--compare') + 1])
      : null;

  final results = await runPerfBenchmark();
  final renameSpeedup =
      results['rename_analyzer_ms']! / results['rename_indexed_ms']!;
  final callersSpeedup =
      results['callers_analyzer_ms']! / results['callers_indexed_ms']!;
  final payload = {
    'generated': DateTime.now().toUtc().toIso8601String(),
    'iterations': _iterations,
    'metrics': results,
    'derived': {
      'rename_speedup_x': double.parse(renameSpeedup.toStringAsFixed(1)),
      'callers_speedup_x': double.parse(callersSpeedup.toStringAsFixed(1)),
    },
  };

  if (writeBaseline) {
    final out = File('benchmarks/perf_baseline.json');
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
    stderr.writeln('wrote ${out.path}');
  }

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));

  if (renameSpeedup < 5) {
    stderr.writeln(
      'PERF REGRESSION: indexed rename is only '
      '${renameSpeedup.toStringAsFixed(1)}x faster than query-time analysis '
      '(minimum 5x)',
    );
    return 1;
  }
  if (callersSpeedup < 5) {
    stderr.writeln(
      'PERF REGRESSION: indexed callers is only '
      '${callersSpeedup.toStringAsFixed(1)}x faster than query-time analysis '
      '(minimum 5x)',
    );
    return 1;
  }

  if (compareFile != null) {
    if (!compareFile.existsSync()) {
      stderr.writeln('baseline missing: ${compareFile.path}');
      exit(1);
    }
    final baseline =
        (jsonDecode(compareFile.readAsStringSync()) as Map)['metrics'] as Map;
    final regressions = <String>[];
    for (final e in results.entries) {
      // Query-time analyzer timings are the deliberately slow side of the
      // paired speedup measurements above. Shared-runner variance there must
      // not fail a release when the indexed path remains at least 5x faster.
      if (!usesAbsoluteBaseline(e.key)) continue;
      final base = (baseline[e.key] as num?)?.toInt();
      if (base == null) continue;
      if (_regressed(base, e.value)) {
        regressions.add('${e.key}: ${base}ms -> ${e.value}ms');
      }
    }
    if (regressions.isNotEmpty) {
      stderr.writeln('PERF REGRESSION:');
      for (final r in regressions) {
        stderr.writeln('  $r');
      }
      exit(1);
    }
    stderr.writeln('perf compare: OK (no regressions beyond thresholds)');
  }

  return 0;
}
