import 'dart:io';

import 'package:codegraph/src/files.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Workspace ws;

  setUp(() {
    root = writeFixture();
    ws = Workspace.find(root.path)!;
  });

  tearDown(() => root.deleteSync(recursive: true));

  File file(String rel) => File('${root.path}/$rel');

  test('reports added, changed and removed files, and nothing when quiet', () {
    final tracker = FileTracker(ws);
    final first = tracker.sync();
    expect(first.added, contains('lib/core/keys.dart'));
    expect(first.added, isNot(contains('vendor/legacy.dart')));
    expect(tracker.sync().isEmpty, isTrue);

    file(
      'lib/core/keys.dart',
    ).writeAsStringSync('// edited\n', mode: FileMode.append);
    file('lib/core/new_file.dart').writeAsStringSync('int n = 1;\n');
    file('lib/core/store.dart').deleteSync();
    final delta = tracker.sync();
    expect(delta.changed, ['lib/core/keys.dart']);
    expect(delta.added, ['lib/core/new_file.dart']);
    expect(delta.removed, ['lib/core/store.dart']);
  });

  test('an analysis options change is reported and rescans the file set', () {
    final tracker = FileTracker(ws)..sync();
    file('analysis_options.yaml').writeAsStringSync(
      'analyzer:\n  exclude:\n    - vendor/**\n    - tool/**\n',
    );
    final delta = tracker.sync();
    expect(delta.config, isTrue);
    expect(delta.removed, ['tool/shots.dart']);
  });

  test('restamped files are not reported again', () {
    final tracker = FileTracker(ws)..sync();
    file(
      'lib/core/keys.dart',
    ).writeAsStringSync('// edited\n', mode: FileMode.append);
    tracker.restamp(['lib/core/keys.dart']);
    expect(tracker.sync().isEmpty, isTrue);
  });

  test('state survives a round trip through JSON', () {
    final tracker = FileTracker(ws)..sync();
    final restored = FileTracker.fromJson(
      ws,
      tracker.toJson().cast<String, dynamic>(),
    );
    expect(restored.sync().isEmpty, isTrue);
    expect(restored.files.toSet(), tracker.files.toSet());
  });

  test('paths outside the workspace are not relative', () {
    expect(ws.relativeOrNull('/tmp/elsewhere.dart'), isNull);
    expect(ws.relativeOrNull('lib/core/keys.dart'), 'lib/core/keys.dart');
    expect(() => ws.relative('/tmp/elsewhere.dart'), throwsArgumentError);
  });
}
