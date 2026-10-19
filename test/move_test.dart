import 'dart:io';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/move.dart';
import 'package:codegraph/src/result.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Analysis analysis;
  late Engine engine;

  setUp(() async {
    root = writeFixture();
    void write(String rel, String text) => File('${root.path}/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    write(
      'lib/a/one.dart',
      "import '../core/keys.dart';\n\nString one() => walletKey('1');\n",
    );
    write('lib/a/two.dart', "import 'one.dart';\n\nString two() => one();\n");
    write('lib/io/stub.dart', 'String platform() => "stub";\n');
    write('lib/io/real.dart', 'String platform() => "real";\n');
    write(
      'lib/io/api.dart',
      "import 'stub.dart' if (dart.library.io) 'real.dart';\n\nString api() => platform();\n",
    );
    write('lib/core/parted.dart', "part 'parted.g.dart';\n\nclass Parted {}\n");
    write('lib/core/parted.g.dart', "part of 'parted.dart';\n");
    analysis = await Analysis.open(
      Workspace.find(root.path)!,
      byteStore: '${root.path}.store',
    );
    engine = Engine(analysis);
  });

  tearDown(() async {
    await analysis.dispose();
    root.deleteSync(recursive: true);
    Directory('${root.path}.store').deleteSync(recursive: true);
  });

  String text(Answer a) => a.render(asJson: false, limit: null);
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();
  bool exists(String rel) => File('${root.path}/$rel').existsSync();

  test('package imports keep their style and point at the new path', () async {
    final r = await move(
      engine,
      'lib/core/keys.dart',
      'lib/core/model/keys.dart',
      apply: true,
    );
    expect(r.exit, Exit.ok, reason: text(r));
    expect(exists('lib/core/keys.dart'), isFalse);
    expect(read('lib/core/model/keys.dart'), contains('enum Gate'));
    expect(
      read('lib/core/backend.dart'),
      contains("import 'package:app/core/model/keys.dart';"),
    );
    expect(
      read('lib/a/one.dart'),
      contains("import '../core/model/keys.dart';"),
    );
    expect(text(r), contains('shows no new errors'));
  });

  test(
    'the moved file and its importers get relative paths recomputed',
    () async {
      final r = await move(
        engine,
        'lib/a/one.dart',
        'lib/b/c/one.dart',
        apply: true,
      );
      expect(r.exit, Exit.ok, reason: text(r));
      expect(
        read('lib/b/c/one.dart'),
        contains("import '../../core/keys.dart';"),
      );
      expect(read('lib/a/two.dart'), contains("import '../b/c/one.dart';"));
      final back = await move(
        engine,
        'lib/b/c/one.dart',
        'lib/a/one.dart',
        apply: true,
      );
      expect(back.exit, Exit.ok, reason: text(back));
      expect(Directory('${root.path}/lib/b').existsSync(), isFalse);
    },
  );

  test('conditional imports are rewritten too', () async {
    final r = await move(
      engine,
      'lib/io/real.dart',
      'lib/io/impl/real.dart',
      apply: false,
    );
    expect(r.exit, Exit.ok, reason: text(r));
    expect(
      text(r),
      contains("lib/io/api.dart:1  'real.dart' -> 'impl/real.dart'"),
    );
  });

  test(
    'a library with parts is UNSUPPORTED, an existing target is a usage error',
    () async {
      final parted = await move(
        engine,
        'lib/core/parted.dart',
        'lib/x/parted.dart',
        apply: false,
      );
      expect(parted.exit, Exit.refused);
      expect(text(parted), startsWith('UNSUPPORTED:'));
      final taken = await move(
        engine,
        'lib/a/one.dart',
        'lib/a/two.dart',
        apply: false,
      );
      expect(taken.exit, Exit.usage);
      expect(text(taken), contains('already exists'));
    },
  );

  test('a move into an excluded directory is rolled back', () async {
    final before = read('lib/a/two.dart');
    final r = await move(
      engine,
      'lib/a/one.dart',
      'vendor/one.dart',
      apply: true,
    );
    expect(r.exit, Exit.refused, reason: text(r));
    expect(text(r), contains('is not analyzed'));
    expect(exists('lib/a/one.dart'), isTrue);
    expect(exists('vendor/one.dart'), isFalse);
    expect(read('lib/a/two.dart'), before);
  });

  test('relative URIs between workspace paths', () {
    expect(relativeUri('lib/a/x.dart', 'lib/a/y.dart'), 'y.dart');
    expect(relativeUri('lib/a/x.dart', 'lib/b/c/y.dart'), '../b/c/y.dart');
    expect(relativeUri('lib/b/c/y.dart', 'lib/a/x.dart'), '../../a/x.dart');
    expect(relativeUri('test/t.dart', 'lib/a.dart'), '../lib/a.dart');
  });
}
