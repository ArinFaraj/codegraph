@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tmp;
  late String exe;
  late Map<String, String> env;
  final roots = <Directory>[];

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('codegraph_cli_');
    exe = '${tmp.path}/codegraph';
    final r = await Process.run('dart', [
      'compile',
      'exe',
      'bin/codegraph.dart',
      '-o',
      exe,
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    env = {
      'CODEGRAPH_BYTE_STORE': '${tmp.path}/stores',
      'CODEGRAPH_REGISTRY': '${tmp.path}/registry',
    };
  });

  tearDownAll(() async {
    for (final root in roots) {
      await Process.run(
        exe,
        ['doctor', '--stop'],
        workingDirectory: root.path,
        environment: env,
      );
      root.deleteSync(recursive: true);
    }
    tmp.deleteSync(recursive: true);
  });

  Directory fixture() {
    final root = writeFixture();
    roots.add(root);
    return root;
  }

  Future<ProcessResult> run(
    Directory root,
    List<String> args, {
    Map<String, String> extra = const {},
  }) => Process.run(
    exe,
    args,
    workingDirectory: root.path,
    environment: {...env, ...extra},
  );

  test('version, help, usage and removed verbs', () async {
    final root = fixture();
    expect((await run(root, ['--version'])).stdout, startsWith('codegraph 4.'));
    expect(
      (await run(root, ['help'])).stdout,
      contains('codegraph refs <symbol>'),
    );
    final removed = await run(root, ['readers', 'sessionProvider']);
    expect(removed.exitCode, 64);
    expect(
      removed.stderr,
      contains('Use: codegraph refs <provider> or show <provider>'),
    );
    expect((await run(root, ['find'])).exitCode, 64);
    expect((await run(root, ['refs', 'x', '--bogus'])).exitCode, 64);
  });

  test('outside a package every verb says where to run it', () async {
    final r = await Process.run(
      exe,
      ['find', 'x'],
      workingDirectory: tmp.path,
      environment: env,
    );
    expect(r.exitCode, 66);
    expect(r.stderr, contains('no pubspec.yaml'));
  });

  test('instant verbs need no worker', () async {
    final root = fixture();
    final find = await run(root, ['find', 'Store']);
    expect(find.exitCode, 0);
    expect(find.stdout, contains('class       Store  lib/core/store.dart:1'));
    final show = await run(root, ['show', 'lib/core/session.dart']);
    expect(show.stdout, contains('imported by (2):'));
    final json = await run(root, ['find', 'Store', '--json']);
    expect(json.stdout, contains('"verb": "find"'));
    expect(
      File('${root.path}/.dart_tool/codegraph/worker.json').existsSync(),
      isFalse,
    );
  });

  test('the worker answers, stays fresh after edits, and stops', () async {
    final root = fixture();
    final refs = await run(root, ['refs', 'sessionProvider']);
    expect(refs.exitCode, 0, reason: '${refs.stderr}');
    expect(refs.stdout, contains('deps.ref.read(sessionProvider);'));

    final doctor = await run(root, ['doctor']);
    expect(doctor.stdout, contains('worker: 4.'));

    File('${root.path}/lib/core/late.dart').writeAsStringSync(
      "import 'package:app/core/session.dart';\nfinal late = sessionProvider;\n",
    );
    final again = await run(root, ['refs', 'sessionProvider']);
    expect(again.stdout, contains('lib/core/late.dart:2'));

    final moved = await run(root, [
      'rename',
      'lib/core/keys.dart',
      'lib/core/model/keys.dart',
    ]);
    expect(moved.exitCode, 0, reason: '${moved.stdout}${moved.stderr}');
    expect(
      moved.stdout,
      contains('would move lib/core/keys.dart -> lib/core/model/keys.dart'),
    );

    final show = await run(root, ['show', 'FeatureKey']);
    expect(show.stdout, contains('enum Backend'));

    final each = await run(root, ['refs', 'save']);
    expect(each.exitCode, 0);
    expect(each.stdout, contains('"save" names 3 declarations'));

    final found = await run(root, ['find', 'Store']);
    expect(found.exitCode, 0);
    expect(found.stdout, contains('class       Store  lib/core/store.dart:1'));
    expect(found.stdout, isNot(contains('mention')));
    final file = await run(root, ['show', 'store.dart']);
    expect(file.stdout, startsWith('lib/core/store.dart  ('));

    final stop = await run(root, ['doctor', '--stop']);
    expect(stop.stdout, contains('worker stopped'));
    expect(
      (await run(root, ['doctor'])).stdout,
      contains('worker: not running'),
    );
  });

  test('without a package config, resolved verbs explain the fix', () async {
    final root = fixture();
    File('${root.path}/.dart_tool/package_config.json').deleteSync();
    final r = await run(root, ['refs', 'sessionProvider']);
    expect(r.exitCode, 66);
    expect(r.stderr, contains('pub get'));
    expect((await run(root, ['find', 'Store'])).exitCode, 0);
  });

  test('the worker cap stops the least recently used worker', () async {
    final a = fixture();
    final b = fixture();
    final cap = {'CODEGRAPH_MAX_WORKERS': '1'};
    expect((await run(a, ['refs', 'walletKey'], extra: cap)).exitCode, 0);
    expect((await run(b, ['refs', 'walletKey'], extra: cap)).exitCode, 0);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(
      (await run(a, ['doctor'], extra: cap)).stdout,
      anyOf(contains('worker: not running'), contains('not responding')),
    );
  });
}
