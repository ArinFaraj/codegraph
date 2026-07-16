import 'dart:io';

/// Low-noise progress for analyzer-backed operations that can otherwise appear
/// hung on large workspaces. Output is stderr-only, so JSON/stdout contracts
/// stay unchanged.
class ProgressReporter {
  ProgressReporter(
    this.phase,
    this.total, {
    this.minInterval = const Duration(seconds: 2),
    void Function(String)? sink,
  }) : _sink = sink ?? stderr.writeln;

  final String phase;
  final int total;
  final Duration minInterval;
  final void Function(String) _sink;
  final Stopwatch _watch = Stopwatch();
  Duration _lastEmission = Duration.zero;
  int _lastCompleted = -1;

  void start() {
    if (_watch.isRunning) return;
    _watch.start();
    _emit(0);
  }

  void advance(int completed) {
    if (!_watch.isRunning) start();
    final bounded = completed.clamp(0, total);
    if (bounded == _lastCompleted) return;
    final isDone = bounded == total;
    if (!isDone && _watch.elapsed - _lastEmission < minInterval) return;
    _emit(bounded);
  }

  void _emit(int completed) {
    _lastCompleted = completed;
    _lastEmission = _watch.elapsed;
    final elapsed = _watch.elapsed.inSeconds;
    _sink(
        '$phase: $completed/$total files${elapsed > 0 ? ' (${elapsed}s)' : ''}');
  }
}
