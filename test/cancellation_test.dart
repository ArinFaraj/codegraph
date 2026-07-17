// Cancellation contract (ROADMAP step 4): a cancel honored at a checkpoint
// leaves the tree untouched and exits 130; a cancel arriving inside the
// install/rollback critical section NEVER interrupts it - the rename applies
// fully and the late cancel is disclosed, with no stray staged/backup files.
import 'dart:io';

import 'package:codegraph/src/cancellation.dart';
import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/rename.dart' as rename;
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  test('guard semantics: checkpoint honors cancel only outside critical', () {
    final guard = CancelGuard();
    guard.checkpoint('idle'); // no cancel -> no throw
    guard.requestCancel();
    expect(
        () => guard.checkpoint('resolve'), throwsA(isA<OperationCancelled>()));
    // Inside critical the same pending cancel must NOT interrupt.
    final result = guard.critical(() {
      guard.checkpoint('install');
      return 42;
    });
    expect(result, 42);
    expect(guard.cancelRequested, isTrue);
    expect(() => guard.checkpoint('after'), throwsA(isA<OperationCancelled>()));
  });

  group('rename integration', () {
    late Directory tempDir;
    late Directory originalCwd;

    setUp(() {
      originalCwd = Directory.current;
      tempDir = Directory.systemTemp.createTempSync('codegraph_cancel_');
      writeCodegraphFixture(tempDir);
      writeFixturePackageConfig(tempDir);
      File('${tempDir.path}/lib/cancel_target.dart').writeAsStringSync('''
class Solo {
  void zap() {}
  void go() {
    zap();
  }
}
''');
      Directory.current = tempDir;
      engine.build(const []);
    });

    tearDown(() {
      CancelGuard.debugOverride = null;
      Directory.current = originalCwd;
      tempDir.deleteSync(recursive: true);
    });

    test('cancel before the critical section: exit 130, tree untouched',
        () async {
      final before =
          File('${tempDir.path}/lib/cancel_target.dart').readAsStringSync();
      CancelGuard.debugOverride = CancelGuard()..requestCancel();
      final code = await rename.run(['rename', 'Solo.zap', 'zip', '--apply']);
      expect(code, 130);
      expect(File('${tempDir.path}/lib/cancel_target.dart').readAsStringSync(),
          before,
          reason: 'a checkpoint cancel must leave the tree untouched');
    });

    test(
        'cancel during the critical section: install completes, rename '
        'applied, no stray artifacts', () async {
      final guard = CancelGuard();
      guard.onCriticalEnter = guard.requestCancel;
      CancelGuard.debugOverride = guard;
      final code = await rename.run(['rename', 'Solo.zap', 'zip', '--apply']);
      expect(code, 0,
          reason: 'a mid-install cancel must not fail the operation');
      final text =
          File('${tempDir.path}/lib/cancel_target.dart').readAsStringSync();
      expect(text, contains('void zip()'));
      expect(text, isNot(contains('void zap()')));
      expect(guard.cancelRequested, isTrue);
      final strays = Directory('${tempDir.path}/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('.stage') || f.path.contains('.backup'))
          .toList();
      expect(strays, isEmpty,
          reason: 'no staged/backup artifact may survive a completed install');
    });
  });
}
