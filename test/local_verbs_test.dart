import 'dart:io';

import 'package:codegraph/src/outline.dart';
import 'package:codegraph/src/result.dart';
import 'package:codegraph/src/verbs_local.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Workspace ws;
  late OutlineIndex idx;

  setUpAll(() {
    root = writeFixture();
    ws = Workspace.find(root.path)!;
    idx = OutlineIndex.load(ws);
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  String text(Result r) => r.render(asJson: false, limit: null);

  test(
    'the workspace is the outermost pubspec and honors analysis excludes',
    () {
      expect(ws.root, root.path);
      expect(idx.files.keys, contains('lib/core/keys.dart'));
      expect(idx.files.keys, contains('packages/app_ui/lib/button.dart'));
      expect(idx.files.keys, contains('tool/shots.dart'));
      expect(idx.files.keys, contains('test/home_test.dart'));
      expect(idx.files.keys.where((p) => p.startsWith('vendor/')), isEmpty);
      expect(idx.files.keys.where((p) => p.startsWith('.deps/')), isEmpty);
    },
  );

  test('outline records declarations, providers and provider uses', () {
    final session = idx.files['lib/core/session.dart']!;
    final providers = session.providers.map((d) => d.name).toList();
    expect(providers, ['sessionProvider', 'flagProvider']);
    final greeting = idx.files['lib/core/greeting.dart']!;
    expect(greeting.providers.single.name, 'greetingProvider');
    final home = idx.files['lib/features/home/home_page.dart']!;
    expect(
      home.providerUses.map((u) => '${u.role} ${u.provider}'),
      containsAll([
        'ref.watch sessionProvider',
        'ref.listen sessionProvider',
        'ref.read sessionProvider',
        'ref.invalidate sessionProvider',
        'ref.watch flagProvider',
      ]),
    );
    final keys = idx.files['lib/core/keys.dart']!;
    expect(
      keys.decls.map((d) => d.qualified),
      containsAll([
        'FeatureKey',
        'FeatureKey.key',
        'Gate',
        'Gate.household',
        'walletKey',
        'Loud',
      ]),
    );
  });

  test(
    'find ranks top-level declarations before members, lib before tests',
    () {
      final r = find(idx, 'store');
      final rows = text(r).split('\n').skip(1).toList();
      expect(rows.first, contains('class       Store  lib/core/store.dart'));
      final json = r.json['declarations'] as List;
      expect(
        json.map((d) => (d as Map)['name']),
        containsAll(['Store', 'DiskStore', 'FakeStore']),
      );
      final fake = json.indexWhere((d) => (d as Map)['name'] == 'FakeStore');
      final disk = json.indexWhere((d) => (d as Map)['name'] == 'DiskStore');
      expect(disk, lessThan(fake));
    },
  );

  test('find matches Owner.member and says when nothing matches', () {
    expect(
      text(find(idx, 'Wallets.sandbox')),
      contains('field       Wallets.sandbox  lib/features/labels.dart:14'),
    );
    final none = text(find(idx, 'zzzNothing'));
    expect(none, contains('0 declarations'));
    expect(none, contains('for string literals use rg'));
  });

  test('show file lists outline, imports, importers and provider uses', () {
    final out = text(showFile(idx, 'lib/core/session.dart'));
    expect(out, startsWith('lib/core/session.dart  ('));
    expect(out, contains('sessionProvider = Provider'));
    expect(out, contains('imported by (2):'));
    expect(out, contains('lib/features/home/home_page.dart'));
    expect(out, contains('test/home_test.dart'));
    expect(out, isNot(contains('vendor/legacy.dart')));
  });

  test('show area summarizes a directory and its outside consumers', () {
    expect(areaCandidates(idx, 'home'), ['lib/features/home']);
    final out = text(showArea(idx, 'lib/core'));
    expect(out, contains('lib/core  ('));
    expect(out, contains('sessionProvider'));
    expect(out, contains('most used outside lib/core'));
  });

  test('why prints the import path, in either direction', () {
    final r = why(
      idx,
      'lib/features/home/home_page.dart',
      'lib/core/session.dart',
    );
    expect(text(r), contains('reaches lib/core/session.dart in 1 step'));
    final back = why(idx, 'session.dart', 'home_page.dart');
    expect(text(back), contains('the reverse of what you asked'));
    final none = why(
      idx,
      'lib/core/keys.dart',
      'packages/app_ui/lib/button.dart',
    );
    expect(text(none), contains('not connected'));
  });

  test('the outline cache is reused and refreshed when a file changes', () {
    final file = File('${root.path}/lib/core/keys.dart');
    final again = OutlineIndex.load(ws);
    expect(
      again.files['lib/core/keys.dart']!.decls.length,
      idx.files['lib/core/keys.dart']!.decls.length,
    );
    final original = file.readAsStringSync();
    file.writeAsStringSync('$original\nint addedLater() => 1;\n');
    try {
      final fresh = OutlineIndex.load(ws);
      expect(
        fresh.files['lib/core/keys.dart']!.decls.map((d) => d.name),
        contains('addedLater'),
      );
    } finally {
      file.writeAsStringSync(original);
    }
  });

  test('a new file appears without a manual rebuild', () {
    final file = File('${root.path}/lib/core/late_file.dart')
      ..writeAsStringSync('class LateComer {}\n');
    try {
      expect(
        OutlineIndex.load(ws).files.keys,
        contains('lib/core/late_file.dart'),
      );
    } finally {
      file.deleteSync();
    }
    expect(
      OutlineIndex.load(ws).files.keys,
      isNot(contains('lib/core/late_file.dart')),
    );
  });
}
