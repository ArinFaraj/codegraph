import 'dart:io';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/rename.dart';
import 'package:codegraph/src/rename_answers.dart';
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
  List<String> edits(Answer r) => [
    for (final e in r.toJson()['edits'] as List)
      '${(e as Map)['path']}:${e['line']}',
  ];
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();

  test(
    'a field with this.x renames its named arguments, not a same-named parameter elsewhere',
    () async {
      final r = await rename(
        engine,
        'DetailsView.loading',
        'isLoading',
        apply: false,
      );
      expect(r.exit, Exit.ok, reason: text(r));
      expect(edits(r), [
        'lib/features/home/details_view.dart:2',
        'lib/features/home/details_view.dart:3',
        'lib/features/home/details_view.dart:8',
      ]);
    },
  );

  test(
    'a field reached through super parameters renames the whole chain',
    () async {
      final r = await rename(engine, 'Base.label', 'caption', apply: true);
      expect(r.exit, Exit.ok, reason: text(r));
      final src = read('lib/features/labels.dart');
      expect(src, contains('Base({required this.caption});'));
      expect(src, contains('final String caption;'));
      expect(src, contains('Child({required super.caption});'));
      expect(src, contains("Child makeChild() => Child(caption: 'c');"));
      expect(src, contains("Base makeBase() => Base(caption: 'b');"));
      expect(text(r), contains('shows no new errors'));
    },
  );

  test('a static field renames uses in lib, tool and test', () async {
    final r = await rename(
      engine,
      'Wallets.sandbox',
      'sandboxList',
      apply: false,
    );
    expect(edits(r), [
      'lib/features/labels.dart:14',
      'lib/features/wallet_list.dart:3',
      'test/home_test.dart:15',
      'tool/shots.dart:3',
    ]);
    expect(text(r), contains('string literals mention "sandbox"'));
  });

  test('a method renames its override set, test fakes included', () async {
    final r = await rename(engine, 'DiskStore.save', 'persist', apply: true);
    expect(r.exit, Exit.ok, reason: text(r));
    expect(
      read('lib/core/store.dart'),
      contains('void persist(String value);'),
    );
    expect(read('test/home_test.dart'), contains("FakeStore().persist('x');"));
    expect(
      read('test/home_test.dart'),
      contains('void persist(String value) {}'),
    );
  });

  test(
    'a class rename covers constructors, types, implements and tests',
    () async {
      final r = await rename(engine, 'FeatureKey', 'FeatureId', apply: true);
      expect(r.exit, Exit.ok, reason: text(r));
      expect(
        read('lib/core/keys.dart'),
        contains('abstract interface class FeatureId {'),
      );
      expect(
        read('lib/core/keys.dart'),
        contains('enum Gate implements FeatureId {'),
      );
      expect(
        read('lib/core/backend.dart'),
        contains('enum Backend implements FeatureId {'),
      );
    },
  );

  test('renaming a class renames its constructor declarations', () async {
    final r = await rename(engine, 'Session', 'UserSession', apply: true);
    expect(r.exit, Exit.ok, reason: text(r));
    final src = read('lib/core/session.dart');
    expect(src, contains('class UserSession {'));
    expect(src, contains('  UserSession(this.token);'));
    expect(src, contains("Provider<UserSession>((ref) => UserSession('t'))"));
    expect(read('test/home_test.dart'), contains("UserSession('fake')"));
  });

  test('an enum value rename warns that the name is also data', () async {
    final r = await rename(engine, 'Gate.household', 'homes', apply: false);
    expect(r.exit, Exit.ok, reason: text(r));
    expect(edits(r), [
      'lib/core/keys.dart:7',
      'lib/features/home/home_page.dart:22',
    ]);
    expect(text(r), contains('warning: household is an enum value'));
  });

  test('a provider variable renames every reader', () async {
    final r = await rename(
      engine,
      'sessionProvider',
      'currentSessionProvider',
      apply: true,
    );
    expect(r.exit, Exit.ok, reason: text(r));
    expect(
      read('lib/features/home/home_page.dart'),
      contains('deps.ref.read(currentSessionProvider);'),
    );
    expect(
      read('test/home_test.dart'),
      contains('currentSessionProvider.overrideWith'),
    );
    expect(read('vendor/legacy.dart'), contains('sessionProvider'));
  });

  test('UNSAFE: a call on a dynamic receiver may be a use', () async {
    final r = await rename(engine, 'Buffer.flush', 'drain', apply: true);
    expect(r.exit, Exit.refused);
    expect(
      text(r),
      startsWith('UNSAFE: 1 call to .flush could not be resolved'),
    );
    expect(text(r), contains('lib/core/store.dart:14'));
    expect(read('lib/core/store.dart'), contains('void flush() {}'));
  });

  test('UNSAFE: overriding a member declared outside the workspace', () async {
    File('${root.path}/lib/core/counter.dart').writeAsStringSync('''
import 'package:riverpod/riverpod.dart';

class Counter extends Notifier<int> {
  @override
  int build() => 0;
}
''');
    await engine.refresh();
    final r = await rename(engine, 'Counter.build', 'create', apply: false);
    expect(r.exit, Exit.refused);
    expect(
      text(r),
      contains(
        'declared outside the workspace (package:riverpod/riverpod.dart)',
      ),
    );
  });

  test('UNSAFE: code generation derives names from the declaration', () async {
    final r = await rename(engine, 'greeting', 'salutation', apply: false);
    expect(r.exit, Exit.refused);
    expect(text(r), contains('annotated @riverpod'));
  });

  test('UNSAFE: public API of a publishable package', () async {
    final r = await rename(engine, 'Kit', 'Toolkit', apply: false);
    expect(r.exit, Exit.refused);
    expect(text(r), contains('public API of packages/shared_kit'));
    final ok = await rename(engine, 'AppButton', 'PrimaryButton', apply: false);
    expect(ok.exit, Exit.ok, reason: text(ok));
  });

  test('UNSAFE: privacy changes and collisions', () async {
    expect(
      text(await rename(engine, 'walletKey', '_walletKey', apply: false)),
      contains('changes its library privacy'),
    );
    expect(
      text(await rename(engine, 'walletKey', 'keyIsUnder', apply: false)),
      contains('already declares a top-level keyIsUnder'),
    );
    expect(
      text(await rename(engine, 'DetailsView.loading', 'title', apply: false)),
      contains('DetailsView already has a member named title'),
    );
  });

  test(
    'UNSUPPORTED is distinct from UNSAFE and says a manual rename is fine',
    () async {
      final r = await rename(
        engine,
        'lib/core/session.dart:4',
        'X',
        apply: false,
      );
      expect(r.exit, Exit.refused);
      expect(text(r), startsWith('UNSUPPORTED:'));
      expect(text(r), contains('Renaming by hand is fine'));
    },
  );

  test(
    'a missed reference is caught by post-apply analysis and rolled back',
    () async {
      final before = {
        for (final f in [
          'lib/features/labels.dart',
          'lib/features/wallet_list.dart',
          'tool/shots.dart',
          'test/home_test.dart',
        ])
          f: read(f),
      };
      final plan =
          (await planRename(engine, 'Wallets.sandbox', 'sandboxList')
                  as PlanReady)
              .plan;
      plan.edits.removeAt(1);
      final r = RenameAnswer(plan, await applyRename(engine, plan));
      expect(r.exit, Exit.refused, reason: text(r));
      expect(text(r), contains('rolled back'));
      expect(text(r), contains('lib/features/wallet_list.dart:3'));
      for (final e in before.entries) {
        expect(read(e.key), e.value, reason: e.key);
      }
    },
  );

  test(
    'an edit set that no longer matches the text on disk is not applied',
    () async {
      expect(
        (await rename(engine, 'walletKey', 'walletId', apply: false)).exit,
        Exit.ok,
      );
      final page = File('${root.path}/lib/features/home/home_page.dart');
      page.writeAsStringSync('// moved\n${page.readAsStringSync()}');
      final r = await rename(engine, 'walletKey', 'walletId', apply: true);
      expect(r.exit, Exit.failed);
      expect(
        text(r),
        contains('not applied: source changed since it was analyzed'),
      );
      expect(read('lib/core/keys.dart'), contains('String walletKey('));
    },
  );

  test('invalid names are usage errors', () async {
    expect(
      (await rename(engine, 'walletKey', 'class', apply: false)).exit,
      Exit.usage,
    );
    expect(
      (await rename(engine, 'walletKey', '9x', apply: false)).exit,
      Exit.usage,
    );
    expect(
      (await rename(engine, 'walletKey', 'walletKey', apply: false)).exit,
      Exit.usage,
    );
  });
}
