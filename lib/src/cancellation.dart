// Cooperative cancellation for long-running actuator operations (ROADMAP
// step 4). Contract:
//   - ctrl-C requests cancellation; it is honored at explicit CHECKPOINTS
//     (between files during analysis), never at an arbitrary instruction;
//   - the install/rollback critical section can NEVER be interrupted: a
//     cancel that arrives while edits are being installed is remembered and
//     reported AFTER the section completes (the edits are applied - saying
//     otherwise would be lying about disk state);
//   - a cancel honored before the critical section leaves the working tree
//     untouched and no staged/backup artifact behind (checkpoints are only
//     placed where nothing is staged).
// Exit code for a cancelled operation: 130 (128+SIGINT convention).
import 'dart:async';
import 'dart:io';

class OperationCancelled implements Exception {
  OperationCancelled(this.phase);

  /// The checkpoint phase at which cancellation was honored.
  final String phase;
}

class CancelGuard {
  CancelGuard();

  /// Test seam: when set, [run] uses this guard instead of creating one and
  /// does NOT subscribe to real signals. Tests drive [requestCancel] directly.
  static CancelGuard? debugOverride;

  /// Test seam: invoked at the top of every [critical] body (lets a test
  /// simulate a ctrl-C arriving mid-install without real signals).
  void Function()? onCriticalEnter;

  bool _cancelRequested = false;
  bool _inCritical = false;

  bool get cancelRequested => _cancelRequested;

  void requestCancel() => _cancelRequested = true;

  /// Honors a pending cancel - throws [OperationCancelled] - unless inside the
  /// critical section. Place ONLY where nothing is staged on disk.
  void checkpoint(String phase) {
    if (_cancelRequested && !_inCritical) throw OperationCancelled(phase);
  }

  /// Runs [body] as the uninterruptible critical section. A cancel requested
  /// while inside is NOT honored (the section always completes or rolls back
  /// as one unit); the caller reads [cancelRequested] afterwards to disclose
  /// a too-late cancel.
  T critical<T>(T Function() body) {
    _inCritical = true;
    onCriticalEnter?.call();
    try {
      return body();
    } finally {
      _inCritical = false;
    }
  }

  /// Installs a SIGINT subscription for the duration of [body]. While
  /// subscribed, ctrl-C does not kill the process (Dart disables the default
  /// handler), so the critical section is structurally protected; the signal
  /// only flips [cancelRequested], and checkpoints do the honoring.
  static Future<T> run<T>(Future<T> Function(CancelGuard guard) body) async {
    final override = debugOverride;
    if (override != null) return body(override);
    final guard = CancelGuard();
    StreamSubscription<ProcessSignal>? sub;
    try {
      sub = ProcessSignal.sigint.watch().listen((_) {
        guard.requestCancel();
        stderr.writeln(guard._inCritical
            ? 'cancel requested - finishing the in-flight install/rollback '
                'first (it cannot be interrupted safely)'
            : 'cancel requested - stopping at the next safe point');
      });
    } on SignalException {
      // Platform without SIGINT watch support: run uncancellable.
    }
    try {
      return await body(guard);
    } finally {
      await sub?.cancel();
    }
  }
}
