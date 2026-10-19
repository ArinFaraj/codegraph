import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/result.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Analysis analysis;
  late Engine engine;

  setUpAll(() async {
    root = writeFixture();
    initGit(root);
    final ws = Workspace.find(root.path)!;
    analysis = await Analysis.open(ws, byteStore: '${root.path}.store');
    await analysis.warmUp();
    engine = Engine(analysis);
  });

  tearDownAll(() async {
    await analysis.dispose();
    root.deleteSync(recursive: true);
    Directory('${root.path}.store').deleteSync(recursive: true);
  });

  String text(Answer a) => a.render(asJson: false, limit: null);

  test('refs finds provider reads through a ref held in a field', () async {
    final r = await engine.refs('sessionProvider');
    final out = text(r);
    expect(r.exit, Exit.ok);
    expect(
      out,
      contains(
        'lib/features/home/home_page.dart:9  final session = ref.watch(sessionProvider);',
      ),
    );
    expect(
      out,
      contains(
        'ref.read (1):\n  lib/features/home/home_page.dart:17  deps.ref.read(sessionProvider);',
      ),
    );
    expect(out, contains('ref.listen (1):'));
    expect(out, contains('ref.invalidate (1):'));
    expect(out, contains('tests, override (1):'));
    expect(out, contains('tests, ref.read (1):'));
    expect(out, isNot(contains('vendor/')));
  });

  test('refs groups by role and counts files', () async {
    final r = await engine.refs('Wallets.sandbox');
    final uses = r.toJson()['uses'] as List;
    expect(uses.map((u) => (u as Map)['path']).toSet(), {
      'lib/features/wallet_list.dart',
      'tool/shots.dart',
      'test/home_test.dart',
    });
    expect(text(r), contains('3 uses in 3 files (1 in tests)'));
  });

  test('show lists enum and mixin subtypes the element model knows', () async {
    final out = text(await engine.showSymbol('FeatureKey'));
    expect(out, contains('subtypes (2, transitive):'));
    expect(out, contains('enum Backend  lib/core/backend.dart:3'));
    expect(out, contains('enum Gate  lib/core/keys.dart:6'));
    final loud = text(await engine.showSymbol('Loud'));
    expect(loud, contains('class Announcer  lib/core/keys.dart:24'));
  });

  test('show of a member lists the rest of its override set', () async {
    final out = text(await engine.showSymbol('Store.save'));
    expect(out, contains('DiskStore.save  lib/core/store.dart:7'));
    expect(out, contains('FakeStore.save  test/home_test.dart:8'));
  });

  test('text and JSON come from the same answer', () async {
    final impact = await engine.impact(SymbolSeed('sessionProvider'));
    final json = impact.toJson();
    final out = text(impact);
    for (final path in (json['direct'] as Map).keys) {
      expect(out, contains('  $path  ('));
    }
    final show = (await engine.showSymbol('sessionProvider')).toJson();
    expect(
      (show['readers'] as List).map((u) => (u as Map)['role']),
      containsAll(['ref.watch', 'ref.read', 'ref.listen', 'ref.invalidate']),
    );
  });

  test('show of a provider lists readers by role', () async {
    final out = text(await engine.showSymbol('sessionProvider'));
    expect(
      out,
      startsWith('provider sessionProvider  lib/core/session.dart:8'),
    );
    expect(
      out,
      contains('ref.watch (1):\n  lib/features/home/home_page.dart:9'),
    );
    expect(out, contains('uses: '));
  });

  test('an ambiguous name lists its candidates', () async {
    final r = await engine.refs('save');
    expect(r.exit, Exit.ambiguous);
    expect(text(r), contains('Store.save  lib/core/store.dart:2'));
    final missing = await engine.refs('noSuchThing');
    expect(missing.exit, Exit.failed);
    expect(text(missing), contains('no declaration named "noSuchThing"'));
  });

  test('symbols can be named by file and line or file and name', () async {
    final byLine = await engine.refs('lib/core/keys.dart:16');
    expect(
      text(byLine),
      startsWith('refs walletKey (function, lib/core/keys.dart:16)'),
    );
    final oneLineEnum = await engine.refs('lib/core/keys.dart:26');
    expect(
      text(oneLineEnum),
      startsWith('refs Tone (enum, lib/core/keys.dart:26): 2 uses in 1 file'),
    );
    final byName = await engine.refs(
      'lib/features/labels.dart:Wallets.sandbox',
    );
    expect(text(byName), startsWith('refs Wallets.sandbox (field'));
  });

  test('impact of a symbol walks uses, one step further, and tests', () async {
    final r = await engine.impact(SymbolSeed('walletKey'));
    final out = text(r);
    expect(
      out,
      contains('uses it directly (1):\n  lib/features/home/home_page.dart'),
    );
    expect(r.toJson()['tests'], isEmpty);
    final store = await engine.impact(SymbolSeed('Store'));
    expect(store.toJson()['tests'], ['test/home_test.dart']);
  });

  test('impact --diff seeds from the declarations a hunk touches', () async {
    final file = File('${root.path}/lib/core/keys.dart');
    final original = file.readAsStringSync();
    file.writeAsStringSync(
      original.replaceFirst("'wallet.\$id'", "'wallet.\${id.trim()}'"),
    );
    try {
      await engine.refresh();
      final r = await engine.impact(DiffSeed(null));
      expect((r.toJson()['seeds'] as List).map((s) => (s as Map)['name']), [
        'walletKey',
      ]);
      expect(text(r), contains('lib/features/home/home_page.dart'));
    } finally {
      file.writeAsStringSync(original);
      await engine.refresh();
    }
  });

  test('sync picks up edits, new files and deletions', () async {
    final file = File('${root.path}/lib/core/extra.dart')
      ..writeAsStringSync(
        "import 'package:app/core/keys.dart';\nString x() => walletKey('y');\n",
      );
    try {
      expect(await analysis.sync(), contains('lib/core/extra.dart'));
      engine.filesChanged(['lib/core/extra.dart']);
      final r = await engine.refs('walletKey');
      expect(text(r), contains('lib/core/extra.dart:2'));
    } finally {
      file.deleteSync();
    }
    await engine.refresh();
    expect(text(await engine.refs('walletKey')), isNot(contains('extra.dart')));
  });

  test(
    'every resolved identifier in lib agrees with refs (oracle walk)',
    () async {
      final expected = <String, Set<String>>{};
      for (final path in analysis.files) {
        final unit = await analysis.unit(path);
        if (unit == null) continue;
        unit.unit.accept(_Collector(unit, analysis.workspace, expected));
      }
      for (final name in [
        'sessionProvider',
        'walletKey',
        'Wallets.sandbox',
        'FeatureKey',
        'Gate',
      ]) {
        final r = await engine.refs(name);
        final got = {
          for (final u in r.toJson()['uses'] as List)
            '${(u as Map)['path']}:${u['line']}',
        };
        expect(got, containsAll(expected[name] ?? <String>{}), reason: name);
      }
    },
  );
}

/// Brute-force oracle: records every identifier that resolves to one of the
/// watched declarations, by walking resolved ASTs instead of the index.
class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.unit, this.ws, this.out);

  final ResolvedUnitResult unit;
  final Workspace ws;
  final Map<String, Set<String>> out;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    var e = node.element;
    if (e is PropertyAccessorElement) e = e.variable;
    final name = switch (e) {
      TopLevelVariableElement(name: 'sessionProvider') => 'sessionProvider',
      TopLevelFunctionElement(name: 'walletKey') => 'walletKey',
      FieldElement(name: 'sandbox') => 'Wallets.sandbox',
      _ => null,
    };
    if (name != null && !node.inDeclarationContext()) {
      final line = unit.lineInfo.getLocation(node.offset).lineNumber;
      (out[name] ??= {}).add('${ws.relative(unit.path)}:$line');
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final e = node.element;
    final name = switch (e) {
      ClassElement(name: 'FeatureKey') => 'FeatureKey',
      EnumElement(name: 'Gate') => 'Gate',
      _ => null,
    };
    if (name != null) {
      final line = unit.lineInfo.getLocation(node.name.offset).lineNumber;
      (out[name] ??= {}).add('${ws.relative(unit.path)}:$line');
    }
    super.visitNamedType(node);
  }
}
