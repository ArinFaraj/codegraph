import 'dart:io';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/check.dart';
import 'package:codegraph/src/check_hook.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/result.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

void main() {
  late String root;
  late Analysis analysis;
  late Engine engine;

  void write(String rel, String content) {
    File('$root/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Future<CheckAnswer> checkNow({
    List<String> paths = const [],
    DateTime? since,
  }) async {
    await engine.refresh();
    return await check(
          engine,
          paths: [for (final p in paths) '$root/$p'],
          since: since,
        )
        as CheckAnswer;
  }

  List<String> where(CheckAnswer a) => [
    for (final p in a.problems) '${p.path}:${p.line} ${p.code}',
  ];

  setUpAll(() async {
    root = Directory.systemTemp
        .createTempSync('codegraph_check_')
        .resolveSymbolicLinksSync();
    Directory('$root/.git').createSync();
    write('pubspec.yaml', '''
name: app
publish_to: none
environment:
  sdk: ^3.9.0
flutter:
  assets:
    - assets/missing.txt
''');
    write('analysis_options.yaml', 'analyzer:\n  exclude:\n    - vendor/**\n');
    write('packages/kit/pubspec.yaml', '''
name: kit
publish_to: none
environment:
  sdk: ^3.9.0
''');
    write('packages/kit/analysis_options.yaml', '''
analyzer:
  errors:
    unused_import: ignore
''');
    write('packages/kit/lib/kit.dart', '''
import 'dart:math';

// TODO: say more.
class Kit {}
''');
    write('.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name": "app", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.9"},
    {"name": "kit", "rootUri": "../packages/kit", "packageUri": "lib/", "languageVersion": "3.9"}
  ]
}
''');
    write('lib/a.dart', 'int answer() => 42;\n');
    write('lib/b.dart', "import 'a.dart';\n\nint twice() => answer() * 2;\n");
    write('lib/c.dart', "import 'b.dart';\n\nint four() => twice() * 2;\n");
    write('lib/other.dart', 'int other() => 1;\n');
    write(
      'lib/other_user.dart',
      "import 'other.dart';\n\nint usesOther() => other();\n",
    );
    write('lib/unused.dart', "import 'dart:math';\n\nint one() => 1;\n");
    write('vendor/skip.dart', 'int broken( => ;\n');

    analysis = await Analysis.open(
      Workspace.find(root)!,
      byteStore: '$root.store',
    );
    await analysis.warmUp();
    engine = Engine(analysis);
    engine.ledger = await Ledger.build(engine);
  });

  tearDownAll(() async {
    await analysis.dispose();
    Directory(root).deleteSync(recursive: true);
    Directory('$root.store').deleteSync(recursive: true);
  });

  test('problems follow each package\'s own analysis options', () async {
    expect(await analysis.problems('packages/kit/lib/kit.dart'), isEmpty);
    final unused = await analysis.problems('lib/unused.dart');
    expect(
      [for (final p in unused) '${p.severity} ${p.code}'],
      ['warning unused_import'],
    );
  });

  test('pubspec problems include missing assets', () {
    final problems = analysis.pubspecProblems('pubspec.yaml');
    expect(
      [for (final p in problems) '${p.line} ${p.code}'],
      ['7 asset_does_not_exist'],
    );
  });

  test('check --all lists every problem dart analyze would', () async {
    await engine.refresh();
    final a = await check(engine, all: true);
    expect(a.exit, Exit.failed);
    final text = a.render(asJson: false, limit: null);
    expect(text, contains('lib/unused.dart:1:8  warning  unused_import'));
    expect(text, contains('pubspec.yaml:7:'));
    expect(text, isNot(contains('kit.dart')));
    expect(text, isNot(contains('vendor/')));
    expect(text, isNot(contains('analyzer plugins')));
  });

  test('a breaking edit is reported in its dependents, once', () async {
    write('lib/a.dart', 'int answer2() => 42;\n');
    final first = await checkNow(paths: ['lib/a.dart']);
    expect(where(first), ['lib/b.dart:3 undefined_function']);
    expect(first.exit, Exit.failed);
    expect(
      first.render(asJson: false, limit: null),
      contains('    int twice() => answer() * 2;'),
    );

    final again = await checkNow(paths: ['lib/a.dart']);
    expect(again.problems, isEmpty);
    expect(again.exit, Exit.ok);

    write('lib/a.dart', 'int answer() => 42;\n');
    expect((await checkNow(paths: ['lib/a.dart'])).problems, isEmpty);
  });

  test('a break outside the change is left for whoever caused it', () async {
    write('lib/other.dart', 'int renamed() => 1;\n');
    write('lib/a.dart', 'int answer() => 43;\n');
    final mine = await checkNow(paths: ['lib/a.dart']);
    expect(mine.problems, isEmpty);

    final theirs = await checkNow(paths: ['lib/other.dart']);
    expect(where(theirs), ['lib/other_user.dart:3 undefined_function']);

    write('lib/other.dart', 'int other() => 1;\n');
    expect((await checkNow(paths: ['lib/other.dart'])).problems, isEmpty);
  });

  test('a write found by its time is checked like a named one', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    write(
      'lib/b.dart',
      "import 'a.dart';\n\nint twice() => answer() * 2;\nint x = '';\n",
    );
    final found = await checkNow(since: before);
    expect(found.written, contains('lib/b.dart'));
    expect(where(found), ['lib/b.dart:4 invalid_assignment']);

    write('lib/b.dart', "import 'a.dart';\n\nint twice() => answer() * 2;\n");
    expect((await checkNow(since: before)).problems, isEmpty);
  });

  test('a path through a symlink is the same file', () async {
    final link = Link('${root}_link')..createSync(root);
    addTearDown(link.deleteSync);
    write(
      'lib/c.dart',
      "import 'b.dart';\n\nint four() => twice() * 2;\nint y = '';\n",
    );
    await engine.refresh();
    final a =
        await check(engine, paths: ['${link.path}/lib/c.dart']) as CheckAnswer;
    expect(where(a), ['lib/c.dart:4 invalid_assignment']);
    write('lib/c.dart', "import 'b.dart';\n\nint four() => twice() * 2;\n");
    expect((await checkNow(paths: ['lib/c.dart'])).problems, isEmpty);
  });

  test('a saved ledger remembers what was already known', () async {
    engine.ledger!.save(Workspace.find(root)!);
    write('lib/a.dart', 'int answer3() => 42;\n');
    final restarted = Engine(analysis)
      ..ledger = Ledger.load(Workspace.find(root)!);
    expect(restarted.ledger, isNotNull);
    await restarted.refresh();
    final a =
        await check(restarted, paths: ['$root/lib/a.dart']) as CheckAnswer;
    expect(where(a), ['lib/b.dart:3 undefined_function']);
    write('lib/a.dart', 'int answer() => 42;\n');
    await restarted.refresh();
    await check(restarted, paths: ['$root/lib/a.dart']);
    await engine.refresh();
  });

  test('writes noted while the worker warms up join the next check', () {
    final ws = Workspace.find(root)!;
    final t0 = DateTime(2026, 10, 20, 12);
    Pending.add(ws, CheckRequest(since: t0, json: false, limit: 30));
    Pending.add(
      ws,
      CheckRequest(paths: ['/r/lib/a.dart'], json: false, limit: 30),
    );
    final next = Pending.takeInto(
      ws,
      CheckRequest(
        since: t0.add(const Duration(minutes: 1)),
        json: false,
        limit: 30,
      ),
    );
    expect(next.since, t0);
    expect(next.paths, ['/r/lib/a.dart']);
    final after = CheckRequest(since: t0, json: false, limit: 30);
    expect(identical(Pending.takeInto(ws, after), after), isTrue);
  });

  test('hook input picks the files a tool call could have written', () {
    final now = DateTime(2026, 10, 20, 12);
    expect(
      hookRequest({
        'tool_name': 'Edit',
        'tool_input': {'file_path': '/r/lib/a.dart'},
      }, now)?.paths,
      ['/r/lib/a.dart'],
    );
    expect(
      hookRequest({
        'tool_name': 'Write',
        'tool_input': {'file_path': '/r/README.md'},
      }, now),
      isNull,
    );
    expect(
      hookRequest({'tool_name': 'Bash', 'duration_ms': 500}, now)?.since,
      now.subtract(const Duration(milliseconds: 2500)),
    );
    expect(hookRequest({'tool_name': 'Read'}, now), isNull);
    expect(hookRequest('not a map', now), isNull);
  });
}
