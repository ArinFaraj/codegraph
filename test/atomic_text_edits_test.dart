import 'dart:io';

import 'package:codegraph/src/atomic_text_edits.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('codegraph_atomic_edits_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File fixture(String name, String content) =>
      File('${temp.path}/$name')..writeAsStringSync(content);

  List<FileSystemEntity> leftovers() => temp
      .listSync()
      .where((entity) => entity.path.contains('.codegraph-'))
      .toList();

  test('prepare rejects stale, duplicate, overlapping, and out-of-bounds spans',
      () {
    final file = fixture('a.dart', 'alpha beta gamma\n');
    void refuses(List<AtomicTextEdit> edits, String message) {
      expect(
        () => prepareTextEdits(edits),
        throwsA(isA<AtomicEditException>()
            .having((e) => e.message, 'message', contains(message))),
      );
      expect(file.readAsStringSync(), 'alpha beta gamma\n');
      expect(leftovers(), isEmpty);
    }

    refuses([
      AtomicTextEdit(
          file: file.path,
          offset: 0,
          length: 5,
          expected: 'wrong',
          replacement: 'x'),
    ], 'source changed');
    const edit = AtomicTextEdit(
        file: '', offset: 0, length: 5, expected: 'alpha', replacement: 'x');
    refuses([
      AtomicTextEdit(
          file: file.path,
          offset: edit.offset,
          length: edit.length,
          expected: edit.expected,
          replacement: edit.replacement),
      AtomicTextEdit(
          file: file.path,
          offset: edit.offset,
          length: edit.length,
          expected: edit.expected,
          replacement: edit.replacement),
    ], 'duplicate');
    refuses([
      AtomicTextEdit(
          file: file.path,
          offset: 0,
          length: 5,
          expected: 'alpha',
          replacement: 'x'),
      AtomicTextEdit(
          file: file.path,
          offset: 4,
          length: 5,
          expected: 'a bet',
          replacement: 'y'),
    ], 'overlapping');
    refuses([
      AtomicTextEdit(
          file: file.path,
          offset: 999,
          length: 1,
          expected: 'x',
          replacement: 'y'),
    ], 'outside');
  });

  test('successful multi-file apply preserves BOM, CRLF, Unicode, and mode',
      () {
    final a = File('${temp.path}/a.dart')
      ..writeAsBytesSync([
        0xef,
        0xbb,
        0xbf,
        ...'void oldName() {}\r\n'.codeUnits,
      ]);
    final b = fixture('b.dart', 'const snowman = "☃";\r\noldName();\r\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', a.path]);
    }
    final beforeMode = a.statSync().mode & 0x1ff;
    final prepared = prepareTextEdits([
      AtomicTextEdit(
          file: a.path,
          offset: 5,
          length: 7,
          expected: 'oldName',
          replacement: 'newName'),
      AtomicTextEdit(
          file: b.path,
          offset: b.readAsStringSync().indexOf('oldName'),
          length: 7,
          expected: 'oldName',
          replacement: 'newName'),
    ]);
    applyPreparedTextEdits(prepared);

    final aBytes = a.readAsBytesSync();
    expect(aBytes.take(3), [0xef, 0xbb, 0xbf]);
    expect(a.readAsStringSync(), contains('newName() {}\r\n'));
    expect(b.readAsStringSync(), 'const snowman = "☃";\r\nnewName();\r\n');
    if (!Platform.isWindows) expect(a.statSync().mode & 0x1ff, beforeMode);
    expect(leftovers(), isEmpty);
  });

  test('failure installing the second file restores the first', () {
    final a = fixture('a.dart', 'oldName();\n');
    final b = fixture('b.dart', 'oldName();\n');
    final prepared = prepareTextEdits([
      for (final file in [a, b])
        AtomicTextEdit(
            file: file.path,
            offset: 0,
            length: 7,
            expected: 'oldName',
            replacement: 'newName'),
    ]);

    expect(
      () => applyPreparedTextEdits(
        prepared,
        beforeInstall: (index, _) {
          if (index == 1) throw FileSystemException('injected install failure');
        },
      ),
      throwsA(isA<AtomicEditException>()
          .having((e) => e.ioFailure, 'ioFailure', isTrue)
          .having((e) => e.recoveryPaths, 'recoveryPaths', isEmpty)),
    );
    expect(a.readAsStringSync(), 'oldName();\n');
    expect(b.readAsStringSync(), 'oldName();\n');
    expect(leftovers(), isEmpty);
  });

  test('concurrent drift before a later install rolls back without clobbering',
      () {
    final a = fixture('a.dart', 'oldName();\n');
    final b = fixture('b.dart', 'oldName();\n');
    final prepared = prepareTextEdits([
      for (final file in [a, b])
        AtomicTextEdit(
            file: file.path,
            offset: 0,
            length: 7,
            expected: 'oldName',
            replacement: 'newName'),
    ]);

    expect(
      () => applyPreparedTextEdits(
        prepared,
        beforeInstall: (index, _) {
          if (index == 1) b.writeAsStringSync('concurrent();\n');
        },
      ),
      throwsA(isA<AtomicEditException>()
          .having((e) => e.message, 'message', contains('restored'))
          .having(
            (e) => e.details.join(' '),
            'details',
            contains('immediately before'),
          )),
    );
    expect(a.readAsStringSync(), 'oldName();\n');
    expect(b.readAsStringSync(), 'concurrent();\n');
    expect(leftovers(), isEmpty);
  });

  test('rollback failure retains and reports the recovery backup', () {
    final a = fixture('a.dart', 'oldName();\n');
    final b = fixture('b.dart', 'oldName();\n');
    final prepared = prepareTextEdits([
      for (final file in [a, b])
        AtomicTextEdit(
            file: file.path,
            offset: 0,
            length: 7,
            expected: 'oldName',
            replacement: 'newName'),
    ]);

    AtomicEditException? failure;
    try {
      applyPreparedTextEdits(
        prepared,
        beforeInstall: (index, _) {
          if (index == 1) throw FileSystemException('injected install failure');
        },
        beforeRollback: (index, _) {
          if (index == 0)
            throw FileSystemException('injected rollback failure');
        },
      );
    } on AtomicEditException catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.recoveryPaths, hasLength(1));
    expect(
        File(failure.recoveryPaths.single).readAsStringSync(), 'oldName();\n');
    File(failure.recoveryPaths.single).deleteSync();
  });
}
