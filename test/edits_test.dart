import 'dart:io';

import 'package:codegraph/src/edits.dart';
import 'package:test/test.dart';

void main() {
  late String root;

  setUp(() {
    root = Directory.systemTemp
        .createTempSync('codegraph_edits_')
        .resolveSymbolicLinksSync();
  });
  tearDown(() => Directory(root).deleteSync(recursive: true));

  List<String> listing() => [
    for (final e in Directory(root).listSync(recursive: true))
      e.path.substring(root.length + 1),
  ]..sort();

  test('an edit keeps the file mode and leaves no staging files', () {
    final file = File('$root/run.sh')..writeAsStringSync('echo old\n');
    Process.runSync('chmod', ['755', file.path]);
    final mode = file.statSync().mode;
    applyPreparedTextEdits(
      prepareTextEdits([
        AtomicTextEdit(
          file: file.path,
          offset: 5,
          length: 3,
          expected: 'old',
          replacement: 'new',
        ),
      ]),
    );
    expect(file.readAsStringSync(), 'echo new\n');
    expect(file.statSync().mode, mode);
    expect(listing(), ['run.sh']);
  });

  test('a create and a delete are undone with the directories made', () {
    File('$root/a.dart').writeAsStringSync('a\n');
    final prepared = prepareTextEdits(
      const [],
      create: {'$root/x/y/b.dart': 'b\n'},
      delete: {'$root/a.dart': 'a\n'},
    );
    applyPreparedTextEdits(prepared);
    expect(listing(), ['x', 'x/y', 'x/y/b.dart']);

    restorePreparedTextEdits(prepared);
    expect(listing(), ['a.dart']);
    expect(File('$root/a.dart').readAsStringSync(), 'a\n');
  });

  test('a delete of a file that changed is refused before any write', () {
    File('$root/a.dart').writeAsStringSync('changed\n');
    expect(
      () => prepareTextEdits(
        const [],
        create: {'$root/b.dart': 'b\n'},
        delete: {'$root/a.dart': 'a\n'},
      ),
      throwsA(isA<AtomicEditException>()),
    );
    expect(listing(), ['a.dart']);
  });
}
