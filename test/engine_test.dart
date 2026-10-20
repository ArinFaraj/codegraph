import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/refs.dart';
import 'package:codegraph/src/show.dart';
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
    final r = await refs(engine, 'sessionProvider');
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
    final r = await refs(engine, 'Wallets.sandbox');
    final uses = r.toJson()['uses'] as List;
    expect(uses.map((u) => (u as Map)['path']).toSet(), {
      'lib/features/wallet_list.dart',
      'tool/shots.dart',
      'test/home_test.dart',
    });
    expect(text(r), contains('3 uses in 3 files (1 in tests)'));
  });

  test('show lists enum and mixin subtypes the element model knows', () async {
    final out = text(await showSymbol(engine, 'FeatureKey'));
    expect(out, contains('subtypes (2, transitive):'));
    expect(out, contains('enum Backend  lib/core/backend.dart:3'));
    expect(out, contains('enum Gate  lib/core/keys.dart:6'));
    final loud = text(await showSymbol(engine, 'Loud'));
    expect(loud, contains('class Announcer  lib/core/keys.dart:24'));
  });

  test('show of a member lists the rest of its override set', () async {
    final out = text(await showSymbol(engine, 'Store.save'));
    expect(out, contains('DiskStore.save  lib/core/store.dart:7'));
    expect(out, contains('FakeStore.save  test/home_test.dart:8'));
  });

  test('text and JSON come from the same answer', () async {
    final answer = await refs(engine, 'sessionProvider');
    final out = text(answer);
    for (final use in answer.toJson()['uses'] as List) {
      final u = use as Map;
      expect(out, contains('  ${u['path']}:${u['line']}  '));
    }
    final show = (await showSymbol(engine, 'sessionProvider')).toJson();
    expect(
      (show['readers'] as List).map((u) => (u as Map)['role']),
      containsAll(['ref.watch', 'ref.read', 'ref.listen', 'ref.invalidate']),
    );
  });

  test('show of a provider lists readers by role', () async {
    final out = text(await showSymbol(engine, 'sessionProvider'));
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

  test('a name shared by a few declarations is answered for each', () async {
    final r = await refs(engine, 'save');
    expect(r.exit, Exit.ok);
    final out = text(r);
    expect(out, startsWith('"save" names 3 declarations; each is answered'));
    expect(out, contains('refs Store.save (method, lib/core/store.dart:2)'));
    expect(out, contains('refs DiskStore.save (method'));
    expect(
      out,
      contains('refs FakeStore.save (method, test/home_test.dart:8)'),
    );
    expect((r.toJson()['answers'] as List).length, 3);
    final missing = await refs(engine, 'noSuchThing');
    expect(missing.exit, Exit.failed);
    expect(text(missing), contains('no declaration named "noSuchThing"'));
  });

  test('show prints the declaration\'s source with line numbers', () async {
    final provider = text(await showSymbol(engine, 'sessionProvider'));
    expect(
      provider,
      contains(
        '8  final sessionProvider = Provider<Session>((ref) => Session(\'t\'));',
      ),
    );
    final type = text(await showSymbol(engine, 'Deps'));
    expect(
      type,
      contains('  Holds a ref so feature code can read providers later.'),
    );
    expect(type, contains('13  class Deps {\n14    Deps(this.ref);'));
    expect(type, isNot(contains('members:')));
    final json = (await showSymbol(engine, 'Deps')).toJson();
    expect((json['source'] as Map)['firstLine'], 13);
  });

  test('refs -C prints numbered context around each use', () async {
    final ctx = text(await refs(engine, 'Wallets.sandbox', context: 1));
    expect(
      ctx,
      contains(
        '  lib/features/wallet_list.dart:3\n'
        '      2  \n'
        '    > 3  int walletCount() => Wallets.sandbox.length;',
      ),
    );
  });

  test('symbols can be named by file and line or file and name', () async {
    final byLine = await refs(engine, 'lib/core/keys.dart:16');
    expect(
      text(byLine),
      startsWith('refs walletKey (function, lib/core/keys.dart:16)'),
    );
    final oneLineEnum = await refs(engine, 'lib/core/keys.dart:26');
    expect(
      text(oneLineEnum),
      startsWith('refs Tone (enum, lib/core/keys.dart:26): 2 uses in 1 file'),
    );
    final byName = await refs(
      engine,
      'lib/features/labels.dart:Wallets.sandbox',
    );
    expect(text(byName), startsWith('refs Wallets.sandbox (field'));
  });

  test('sync picks up edits, new files and deletions', () async {
    final file = File('${root.path}/lib/core/extra.dart')
      ..writeAsStringSync(
        "import 'package:app/core/keys.dart';\nString x() => walletKey('y');\n",
      );
    try {
      expect((await engine.refresh()).added, ['lib/core/extra.dart']);
      final r = await refs(engine, 'walletKey');
      expect(text(r), contains('lib/core/extra.dart:2'));
    } finally {
      file.deleteSync();
    }
    await engine.refresh();
    expect(
      text(await refs(engine, 'walletKey')),
      isNot(contains('extra.dart')),
    );
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
        final r = await refs(engine, name);
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
