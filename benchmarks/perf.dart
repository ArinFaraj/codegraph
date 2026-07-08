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

import '../test/fixture.dart';

const _iterations = 5;
const _regressionPct = 15.0;
const _regressionAbsMs = 25.0;

typedef _BenchFn = void Function();

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

Map<String, int> runPerfBenchmark() {
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

    return {...buildOnly, ...queries};
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

int main(List<String> args) {
  final writeBaseline = args.contains('--write-baseline');
  final compareFile = args.contains('--compare')
      ? File(args[args.indexOf('--compare') + 1])
      : null;

  final results = runPerfBenchmark();
  final payload = {
    'generated': DateTime.now().toUtc().toIso8601String(),
    'iterations': _iterations,
    'metrics': results,
  };

  if (writeBaseline) {
    final out = File('benchmarks/perf_baseline.json');
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
    stderr.writeln('wrote ${out.path}');
  }

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));

  if (compareFile != null) {
    if (!compareFile.existsSync()) {
      stderr.writeln('baseline missing: ${compareFile.path}');
      exit(1);
    }
    final baseline =
        (jsonDecode(compareFile.readAsStringSync()) as Map)['metrics'] as Map;
    final regressions = <String>[];
    for (final e in results.entries) {
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
