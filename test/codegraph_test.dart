// End-to-end smoke test: builds the graph for a small fixture project (an app
// + a local package) and checks the extraction and query logic that's most
// likely to regress silently — package-import resolution, provider wiring,
// navigation capture, and symbol lookup.
import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/cli_util.dart' as cli_util;
import 'package:codegraph/src/doctor.dart' as doctor;
import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/init.dart' as scaffold;
import 'package:codegraph/src/lint.dart' as lint;
import 'package:codegraph/src/model.dart';
import 'package:codegraph/src/query.dart' as query;
import 'package:codegraph/src/version_skew.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tempDir;
  late Directory originalCwd;

  // Stdout-content assertions (ranked find, sym card, skeleton, --json) need
  // the real CLI process — `dart:io`'s `Stdout` has no public constructor, so
  // in-process capture isn't available. Compile once to a kernel snapshot
  // (~60ms/run after) rather than `dart run` per assertion (~4s/run, package
  // resolution + JIT every time).
  late String cliSnapshot;

  // PATH with `dart` and `chmod` available (init shells out to chmod) but
  // genuinely NO `git`, so Process.runSync('git', ...) throws
  // ProcessException. `/bin` cannot be used for chmod here: on merged-/usr
  // Linux (Ubuntu's /bin -> /usr/bin symlink) that would put git back on the
  // PATH — which is exactly how this broke in CI while passing on macOS.
  // Instead chmod is symlinked alone into a temp dir (populated in setUpAll).
  late String gitlessPath;

  setUpAll(() {
    originalCwd = Directory.current;
    final toolDir = Directory.systemTemp.createTempSync('codegraph_gitless_');
    final chmod = Process.runSync('which', ['chmod']).stdout.toString().trim();
    if (chmod.isNotEmpty) {
      Link('${toolDir.path}/chmod').createSync(chmod);
    }
    gitlessPath =
        '${File(Platform.resolvedExecutable).parent.path}:${toolDir.path}';
    cliSnapshot =
        '${Directory.systemTemp.createTempSync('codegraph_cli_').path}/cli.dill';
    final result = Process.runSync('dart', [
      'compile',
      'kernel',
      '${originalCwd.path}/bin/codegraph.dart',
      '-o',
      cliSnapshot,
    ]);
    if (result.exitCode != 0) {
      throw StateError('failed to compile codegraph CLI: ${result.stderr}');
    }
  });

  setUp(() {
    originalCwd = Directory.current;
    tempDir = Directory.systemTemp.createTempSync('codegraph_test_');
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;
  });

  tearDown(() {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  test('build() resolves package: imports from an app and a local package', () {
    engine.build(const []);

    final graph =
        jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
            as Map<String, dynamic>;
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

    // Symbol from the local package was captured, as a record (not a bare
    // name) with kind/line/sig/doc/members.
    final button = nodes.firstWhere(
      (n) => n['id'] == 'file:packages/fixture_ui/lib/fancy_button.dart',
    );
    final symbols = (button['symbols'] as List).cast<Map<String, dynamic>>();
    final fancyButton = symbols.firstWhere((s) => s['n'] == 'FancyButton');
    expect(fancyButton['k'], 'class');
    expect(fancyButton['l'], 2);
    expect(fancyButton['sig'], contains('class FancyButton'));
    expect(fancyButton['doc'], 'A fancy button widget.');
    final members = (fancyButton['members'] as List).cast<String>();
    expect(members.any((m) => m.contains('press()')), isTrue);

    // Top-level function with params was captured too.
    final formatFile = nodes.firstWhere(
      (n) => n['id'] == 'file:packages/fixture_ui/lib/format.dart',
    );
    final formatSymbols =
        (formatFile['symbols'] as List).cast<Map<String, dynamic>>();
    final formatFn = formatSymbols.single;
    expect(formatFn['n'], 'formatLabel');
    expect(formatFn['k'], 'fn');
    expect(formatFn['sig'], contains('formatLabel(String raw'));

    // The app's self-package import (package:fixture/...) resolved.
    final homePage = nodes.firstWhere(
      (n) => n['id'] == 'file:lib/home/home_page.dart',
    );
    expect(homePage, isNotNull);

    // homeProvider node has a line.
    final homeProviderNode = nodes.firstWhere(
      (n) => n['kind'] == 'provider' && n['name'] == 'homeProvider',
    );
    expect(homeProviderNode['line'], 1);

    // Provider watch edge + navigation target were captured, with a line
    // matching the fixture (ref.watch(homeProvider) is on line 6).
    final watchesHome = edges.where(
      (e) =>
          e['src'] == 'file:lib/home/home_page.dart' && e['rel'] == 'watches',
    );
    expect(watchesHome, hasLength(1));
    expect(watchesHome.first['dst'], 'provider:homeProvider');
    expect(watchesHome.first['line'], 6);

    final navEdge = edges.firstWhere((e) => e['rel'] == 'navigates');
    expect(navEdge['dst'], "route:'/details'");
  });

  test(
    'a const list of provider-kind name strings is not mistaken for a '
    'provider declaration',
    () {
      File('lib/home/provider_kind_names.dart').writeAsStringSync('''
const kinds = ['AsyncNotifierProvider', 'Provider'];
''');
      engine.build(const []);

      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();

      // No provider node was created from this file's top-level variable.
      final fromKindsFile = nodes.where(
        (n) =>
            n['kind'] == 'provider' &&
            n['declaredIn'] == 'lib/home/provider_kind_names.dart',
      );
      expect(fromKindsFile, isEmpty);

      // The existing real declaration (`Provider<int>((ref) => 1)`) is
      // untouched by the tightened heuristic.
      final homeProviderNode = nodes.firstWhere(
        (n) => n['kind'] == 'provider' && n['name'] == 'homeProvider',
      );
      expect(homeProviderNode['providerType'], 'Provider');
    },
  );

  test(
    'duplicate provider names resolve per-reader via import reachability, '
    'not last-write-wins',
    () {
      engine.build(const []);

      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      // Both declarations of `dupProvider` get their own node — neither is
      // silently dropped by a last-write-wins registry.
      final dupNodes = nodes.where(
        (n) => n['kind'] == 'provider' && n['name'] == 'dupProvider',
      );
      expect(dupNodes, hasLength(2));
      expect(dupNodes.every((n) => n['ambiguous'] == true), isTrue);

      final aId = 'provider:dupProvider@lib/dup/a_provider.dart';
      final bId = 'provider:dupProvider@lib/dup/b_provider.dart';
      expect(dupNodes.map((n) => n['id']), containsAll([aId, bId]));

      // a_reader.dart only imports a_provider.dart, so its watch edge must
      // resolve to the `a` declaration, never to `b` and never merged.
      final aReaderEdges = edges.where(
        (e) =>
            e['src'] == 'file:lib/dup/a_reader.dart' && e['rel'] == 'watches',
      );
      expect(aReaderEdges, hasLength(1));
      expect(aReaderEdges.first['dst'], aId);

      // b_reader.dart only imports b_provider.dart: must resolve to `b`.
      final bReaderEdges = edges.where(
        (e) =>
            e['src'] == 'file:lib/dup/b_reader.dart' && e['rel'] == 'watches',
      );
      expect(bReaderEdges, hasLength(1));
      expect(bReaderEdges.first['dst'], bId);

      // query readers() must report both declarations separately, not merge
      // b_reader.dart's watch onto a's declaration (the bug this fixes).
      expect(query.run(['readers', 'dupProvider']), 0);
    },
  );

  test('query find() locates a symbol defined in a local package', () {
    engine.build(const []);
    final exitCode = query.run(['find', 'FancyButton']);
    expect(exitCode, 0);
  });

  test('query readers() reports the consumer of a provider', () {
    engine.build(const []);
    final exitCode = query.run(['readers', 'homeProvider']);
    expect(exitCode, 0);
  });

  test(
    'readers --json --budget caps TOTAL items across sections, not per '
    'section',
    () {
      engine.build(const []);
      final result = Process.runSync('dart', [
        cliSnapshot,
        'readers',
        'budgetProvider',
        '--json',
        '--budget',
        '1',
      ]);
      expect(result.exitCode, 0);
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final results = (decoded['results'] as List).cast<Map<String, dynamic>>();
      final totalItems = results.fold<int>(
        0,
        (sum, r) =>
            sum +
            ['watches', 'reads', 'listens']
                .map((k) => (r[k] as List?)?.length ?? 0)
                .fold(0, (a, b) => a + b),
      );
      // budgetProvider has one watcher (budget_watcher.dart) AND one reader
      // (budget_reader.dart) — with the per-section bypass this would be 2
      // (1 per section); the shared budget must cap the total at 1.
      expect(totalItems, lessThanOrEqualTo(1));
      expect(decoded['truncated'], isTrue);
    },
  );

  test(
    'callers --resolved attributes same-named methods to their real target '
    '(element identity vs name-match lumping)',
    () {
      // Two unrelated classes each declaring `foo`, called once each. Syntax
      // name-match lumps both under "foo (2 declarations)"; element identity
      // attributes each site to A.foo vs B.foo.
      writeFixturePackageConfig(tempDir);
      File('${tempDir.path}/lib/samename.dart').writeAsStringSync('''
class A { int foo() => 1; }
class B { int foo() => 2; }
int useA(A a) => a.foo();
int useB(B b) => b.foo();
''');
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'callers', 'foo', '--resolved', '--json', '--no-rebuild'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(decoded['resolved'], isTrue);
      final targets = (decoded['targets'] as Map).keys.toSet();
      // The whole point: distinct targets, not one lumped `foo`.
      expect(targets, containsAll(<String>['A.foo', 'B.foo']));
    },
  );

  test(
    'callers --resolved reports the override chain (refactor-safety context)',
    () {
      // Derived.compute overrides Base.compute - a signature change must touch
      // both. The resolved path must surface that; syntax name-match cannot.
      writeFixturePackageConfig(tempDir);
      File('${tempDir.path}/lib/override_case.dart').writeAsStringSync('''
class Base { int compute() => 0; }
class Derived extends Base {
  @override
  int compute() => 1;
}
int useD(Derived d) => d.compute();
''');
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [
          cliSnapshot,
          'callers',
          'compute',
          '--resolved',
          '--json',
          '--no-rebuild',
        ],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final overrides = decoded['overrides'] as Map<String, dynamic>?;
      expect(overrides, isNotNull,
          reason: 'Derived.compute overrides Base.compute');
      expect(overrides!.keys, contains('Derived.compute'));
      expect((overrides['Derived.compute'] as List).join(),
          contains('Base.compute'));
    },
  );

  test(
    'rename --apply rewrites only the target element sites, never same-named '
    'siblings on unrelated classes',
    () {
      writeFixturePackageConfig(tempDir);
      File('${tempDir.path}/lib/rn.dart').writeAsStringSync('''
class A { void helper() {} void run() { helper(); } }
class B { void helper() {} void go() { helper(); } }
''');
      engine.build(const []);
      final res = Process.runSync(
        'dart',
        [cliSnapshot, 'rename', 'A.helper', 'prep', '--apply', '--no-rebuild'],
      );
      expect(res.exitCode, 0, reason: res.stderr as String);
      final txt = File('${tempDir.path}/lib/rn.dart').readAsStringSync();
      // A's decl + call site renamed; B's identical-named method untouched.
      expect(txt, contains('void prep() {} void run() { prep(); }'));
      expect(txt, contains('void helper() {} void go() { helper(); }'));
    },
  );

  test(
      'rename renames a whole in-project override set together (base + all '
      'overrides + call sites), leaving unrelated same-named methods alone',
      () {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/rn2.dart').writeAsStringSync('''
abstract class Base { int compute(); }
class SubA extends Base { @override int compute() => 1; }
class SubB implements Base { @override int compute() => 2; }
class Free { int compute() => 9; }
int useBase(Base b) => b.compute();
''');
    engine.build(const []);
    final res = Process.runSync(
      'dart',
      [
        cliSnapshot,
        'rename',
        'SubA.compute',
        'calc',
        '--apply',
        '--no-rebuild'
      ],
    );
    expect(res.exitCode, 0, reason: res.stderr as String);
    final txt = File('${tempDir.path}/lib/rn2.dart').readAsStringSync();
    expect(txt, contains('abstract class Base { int calc(); }'));
    expect(txt, contains('class SubA extends Base { @override int calc()'));
    expect(txt, contains('class SubB implements Base { @override int calc()'));
    expect(txt, contains('b.calc()'));
    expect(txt, contains('class Free { int compute() => 9; }')); // untouched
  });

  test('rename refuses an external-base override and an ambiguous name', () {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/rn3.dart').writeAsStringSync('''
import 'package:riverpod/riverpod.dart';

class MyNotifier extends Notifier<int> {
  @override
  int build() => 0;
}
class Freestanding { int build() => 1; }
''');
    engine.build(const []);
    // MyNotifier.build overrides riverpod's Notifier.build (out of project) ->
    // refuse: a rename would break the framework override contract.
    final ext = Process.runSync(
      'dart',
      [cliSnapshot, 'rename', 'MyNotifier.build', 'make', '--no-rebuild'],
    );
    expect(ext.exitCode, 3, reason: ext.stdout as String);
    // Bare `build` spans the MyNotifier set + unrelated Freestanding -> ambiguous.
    final amb = Process.runSync(
      'dart',
      [cliSnapshot, 'rename', 'build', 'make', '--no-rebuild'],
    );
    expect(amb.exitCode, 3);
  });

  test(
    'brief on a provider with 12+ fan-in importers keeps every line under '
    '~700 chars, with a … more marker on the capped line',
    () {
      engine.build(const []);
      final result = Process.runSync('dart', [
        cliSnapshot,
        'brief',
        'fanin_target.dart',
        '--budget',
        '999',
      ]);
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      final lines = out.split('\n');
      for (final line in lines) {
        expect(line.length, lessThan(700), reason: line);
      }
      final importedByLine = lines.firstWhere(
        (l) => l.startsWith('imported-by ('),
      );
      expect(importedByLine, contains('… '));
    },
  );

  test('extension type produces a symbol record (kind ext-type)', () {
    engine.build(const []);

    final graph =
        jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
            as Map<String, dynamic>;
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    final metersFile = nodes.firstWhere(
      (n) => n['id'] == 'file:lib/sig/meters.dart',
    );
    final symbols =
        (metersFile['symbols'] as List).cast<Map<String, dynamic>>();
    final meters = symbols.singleWhere((s) => s['n'] == 'Meters');
    expect(meters['k'], 'ext-type');
    expect(meters['sig'], contains('extension type Meters(double value)'));

    final result = Process.runSync('dart', [cliSnapshot, 'find', 'Meters']);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('Meters'));
  });

  test('find matches a class MEMBER (method), not just top-level names', () {
    engine.build(const []);
    // SamplePage.render() is a method — before the member-index fix, `find
    // render` returned nothing (only top-level symbol names were searchable),
    // forcing a grep fallback. It must now surface as `Class.member — file`.
    final result = Process.runSync('dart', [cliSnapshot, 'find', 'render']);
    expect(result.exitCode, 0);
    expect(result.stdout as String,
        contains('member: SamplePage.render — lib/features/sample'));
  });

  test('find matches members past the 12-member render cap via memberIndex',
      () {
    engine.build(const []);
    final result = Process.runSync('dart', [cliSnapshot, 'find', 'm13']);
    expect(result.exitCode, 0);
    expect(
      result.stdout as String,
      contains('member: ManyMembers.m13 — lib/sig/many_members'),
    );
  });

  test(
      'callers lists exact call sites (not the declaration); refs adds the '
      'tear-off', () {
    engine.build(const []);
    final callers = Process.runSync(
        'dart', [cliSnapshot, 'callers', 'pingTarget', '--json']);
    final cj = jsonDecode(callers.stdout as String) as Map<String, dynamic>;
    final callHits = (cj['hits'] as List).cast<Map<String, dynamic>>();
    // 3 CALL sites (a→1, b→1, b's f() is a call of the local, not pingTarget)
    // — caller_a.dart:2 and caller_b.dart twice. The declaration is NOT listed.
    expect(callHits.every((h) => h['kind'] == 'call'), isTrue);
    expect(
        callHits.any(
            (h) => h['file'] == 'lib/calls/caller_a.dart' && h['line'] == 2),
        isTrue);
    expect(callHits.any((h) => h['file'] == 'lib/calls/target.dart'), isFalse,
        reason: 'the declaration site must not be a caller');
    // refs is a superset: it also surfaces the tear-off `final f = pingTarget`.
    final refs =
        Process.runSync('dart', [cliSnapshot, 'refs', 'pingTarget', '--json']);
    final rj = jsonDecode(refs.stdout as String) as Map<String, dynamic>;
    final refHits = (rj['hits'] as List).cast<Map<String, dynamic>>();
    expect(refHits.any((h) => h['kind'] == 'ref'), isTrue,
        reason: 'the tear-off must appear as a [ref] in refs mode');
  });

  test('callchain walks the call tree and flags control-flow hazards', () {
    engine.build(const []);
    final r = Process.runSync(
        'dart', [cliSnapshot, 'callchain', 'chainEntry', '--json']);
    expect(r.exitCode, 0);
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final root = (j['roots'] as List).first as Map<String, dynamic>;
    expect(root['name'], 'chainEntry');
    // chainEntry -> chainMid[guard] -> chainLeaf[swallow]
    final mid = (root['calls'] as List).first as Map<String, dynamic>;
    expect(mid['name'], 'chainMid');
    expect((mid['hazards'] as List), contains('guard'));
    final leaf = (mid['calls'] as List).first as Map<String, dynamic>;
    expect(leaf['name'], 'chainLeaf');
    expect((leaf['hazards'] as List), contains('swallow'));
    // chainLeaf calls chainEntry back — must be a cycle guard, not infinite.
    expect(leaf['calls'], anyOf(isNull, isA<List>()));
  });

  test('readers on a Notifier provider appends the shape-change hint', () {
    engine.build(const []);
    final r =
        Process.runSync('dart', [cliSnapshot, 'readers', 'counterProvider']);
    expect(r.exitCode, 0);
    final out = r.stdout as String;
    // readers lists consumers; the hint must point a shape-change at impls +
    // sym with the ACTUAL notifier + state class names (not shown by readers).
    expect(out, contains('shape change?'));
    expect(out, contains('impls CounterNotifier'));
    expect(out, contains('sym CounterState'));
  });

  test('readers on a plain (non-Notifier) provider has no shape-change hint',
      () {
    engine.build(const []);
    final r = Process.runSync('dart', [cliSnapshot, 'readers', 'homeProvider']);
    expect((r.stdout as String).contains('shape change?'), isFalse);
  });

  test(
      'BARE read/watch/listen(provider) inside an `extension on Ref` is '
      'detected (implicit receiver)', () {
    engine.build(const []);
    // counter_ref_ext.dart reads/watches/listens counterProvider with NO `ref.`
    // prefix — all three edges were invisible before the Ref-extension fix.
    final graph =
        jsonDecode(File('docs/maps/code_graph.json').readAsStringSync()) as Map;
    final edges = (graph['edges'] as List).cast<Map>();
    for (final rel in ['reads', 'watches', 'listens']) {
      expect(
        edges.any((e) =>
            e['src'] == 'file:lib/notif/counter_ref_ext.dart' &&
            e['rel'] == rel &&
            (e['dst'] as String).contains('counterProvider')),
        isTrue,
        reason: 'bare $rel(counterProvider) in a Ref extension must be an edge',
      );
    }
    // ProviderContainer.read(provider) is credited too (distinct receiver).
    expect(
      edges.any((e) =>
          e['src'] == 'file:lib/notif/counter_container_reader.dart' &&
          e['rel'] == 'reads' &&
          (e['dst'] as String).contains('counterProvider')),
      isTrue,
      reason: 'container.read(counterProvider) must be a read edge',
    );
  });

  test(
      'CASCADE ref..listen(p)..read(q) is detected; a cascade on a non-ref '
      'receiver is NOT (realTarget + _refReceivers gate)', () {
    engine.build(const []);
    final graph =
        jsonDecode(File('docs/maps/code_graph.json').readAsStringSync()) as Map;
    final edges = (graph['edges'] as List).cast<Map>();
    // Positive: both cascade sections credit counterProvider.
    for (final rel in ['listens', 'reads']) {
      expect(
        edges.any((e) =>
            e['src'] == 'file:lib/notif/counter_cascade_reader.dart' &&
            e['rel'] == rel &&
            (e['dst'] as String).contains('counterProvider')),
        isTrue,
        reason: 'cascade $rel(counterProvider) on a ref must be an edge',
      );
    }
    // Negative / refusal: a cascade on a non-ref receiver must NOT be credited.
    expect(
      edges.any((e) =>
          e['src'] == 'file:lib/notif/non_ref_cascade.dart' &&
          (e['dst'] as String).contains('counterProvider')),
      isFalse,
      reason: '`_Bag()..listen(counterProvider)` is not a ref read',
    );
  });

  test('find splits a spaced single arg into terms (phrase no longer misses)',
      () {
    engine.build(const []);
    // `find "fancy button"` (ONE quoted arg with a space) used to substring-match
    // the whole "fancy button" — which no identifier contains — and return
    // nothing. It must now match FancyButton like the two-arg form does.
    final quoted =
        Process.runSync('dart', [cliSnapshot, 'find', 'fancy button']);
    expect(quoted.exitCode, 0);
    expect((quoted.stdout as String), contains('FancyButton'),
        reason: 'quoted phrase must match the camelCase symbol');
  });

  test(
      'readers on a non-provider symbol redirects to find/wiring '
      '(not "misspelled")', () {
    engine.build(const []);
    final r = Process.runSync('dart', [cliSnapshot, 'readers', 'FancyButton']);
    final out = r.stdout as String;
    expect(out, contains('not a provider'));
    expect(out, contains('find FancyButton'));
    expect(out.contains('misspelled'), isFalse,
        reason: 'a real symbol name is not misspelled');
  });

  test('readers non-provider redirect is case-insensitive on symbol name', () {
    engine.build(const []);
    final r = Process.runSync('dart', [cliSnapshot, 'readers', 'fancyButton']);
    final out = r.stdout as String;
    expect(out, contains('FancyButton is a class, not a provider'));
    expect(out, contains('find FancyButton'));
    expect(out.contains('misspelled'), isFalse);
  });

  test(
    'sig rendering: static, operator, factory, sealed all show up in '
    'emitted sigs',
    () {
      engine.build(const []);

      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
      final shapesFile = nodes.firstWhere(
        (n) => n['id'] == 'file:lib/sig/shapes.dart',
      );
      final symbols =
          (shapesFile['symbols'] as List).cast<Map<String, dynamic>>();

      final shape = symbols.singleWhere((s) => s['n'] == 'Shape');
      expect(shape['sig'], contains('sealed class Shape'));
      final shapeMembers = (shape['members'] as List).cast<String>();
      expect(shapeMembers.any((m) => m.contains('static')), isTrue);
      expect(shapeMembers.any((m) => m.contains('factory ')), isTrue);

      final circle = symbols.singleWhere((s) => s['n'] == 'Circle');
      final circleMembers = (circle['members'] as List).cast<String>();
      expect(circleMembers.any((m) => m.contains('operator +')), isTrue);
    },
  );

  test('impls is TRANSITIVE — the full subtype tree, not just direct children',
      () {
    engine.build(const []);
    final r = Process.runSync('dart', [cliSnapshot, 'impls', 'Shape']);
    expect(r.exitCode, 0);
    final out = r.stdout as String;
    // Direct child AND grandchild both appear (Shape -> Circle -> NamedCircle).
    expect(out, contains('Circle -> Shape'));
    expect(out, contains('NamedCircle -> Circle'));
    // JSON carries the depth so a consumer can render the tree.
    final j =
        Process.runSync('dart', [cliSnapshot, 'impls', 'Shape', '--json']);
    final results = (jsonDecode(j.stdout as String)
        as Map<String, dynamic>)['results'] as List;
    final named = results
        .cast<Map<String, dynamic>>()
        .singleWhere((e) => e['subtype'] == 'NamedCircle');
    expect(named['depth'], 1); // grandchild is depth 1
    expect(named['supertype'], 'Circle');
  });

  test(
      'duplicate class name: implements/extends refuses first-wins '
      '(ambiguous + candidates) unless reachability narrows it — 0.9.4', () {
    // Two features each declare `DupBase`; the class registry used to be
    // first-wins, so a subtype edge silently pointed at whichever file parsed
    // first. It must now refuse (like ambiguous providers) when it can't reach
    // exactly one declaration, and resolve only when reachability narrows it.
    File('lib/ambig/a/dup_base.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class DupBase {}\n');
    File('lib/ambig/b/dup_base.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class DupBase {}\n');
    // C reaches NEITHER declaration → must refuse.
    File('lib/ambig/c/user.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class DupUser extends DupBase {}\n');
    // D imports only feature a → reachability narrows to the one declaration.
    File('lib/ambig/d/narrowed.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("import 'package:fixture/ambig/a/dup_base.dart';\n"
          'class NarrowedUser extends DupBase {}\n');
    engine.build(const []);
    final graph =
        jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
            as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

    final cEdge = edges.firstWhere((e) =>
        e['src'] == 'file:lib/ambig/c/user.dart' &&
        e['rel'] == 'implements/extends');
    expect(cEdge['dst'], 'type:DupBase',
        reason: 'unreachable duplicate must refuse, not first-wins to a file');
    expect(cEdge['ambiguous'], isTrue);
    expect(
      (cEdge['candidates'] as List).cast<String>(),
      containsAll(<String>[
        'lib/ambig/a/dup_base.dart',
        'lib/ambig/b/dup_base.dart',
      ]),
    );

    final dEdge = edges.firstWhere((e) =>
        e['src'] == 'file:lib/ambig/d/narrowed.dart' &&
        e['rel'] == 'implements/extends');
    expect(dEdge['dst'], 'file:lib/ambig/a/dup_base.dart',
        reason: 'reachability narrows to the one imported declaration');
    expect(dEdge.containsKey('ambiguous'), isFalse);
  });

  test('ranked find() sorts by in-degree, symbol hits show :line', () {
    engine.build(const []);
    final result = Process.runSync('dart', [cliSnapshot, 'find', 'home']);
    expect(result.exitCode, 0);
    final lines = (result.stdout as String)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();

    // home_helper.dart has in-degree 2 (two readers); home_zzz_orphan.dart
    // has in-degree 0 — the 2-importer file must rank first.
    final helperIdx = lines.indexWhere((l) => l.contains('home_helper.dart'));
    final orphanIdx = lines.indexWhere(
      (l) => l.contains('home_zzz_orphan.dart'),
    );
    expect(helperIdx, greaterThanOrEqualTo(0));
    expect(orphanIdx, greaterThanOrEqualTo(0));
    expect(helperIdx, lessThan(orphanIdx));
    expect(lines[helperIdx], contains('·2⇐'));

    // Symbol hits carry their declaration line.
    final symbolLine = lines.firstWhere(
      (l) => l.startsWith('symbol: formatHomeTitle'),
    );
    expect(symbolLine, contains(':2'));
  });

  test('find --json parses and contains ranked results', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'find',
      'home',
      '--json',
    ]);
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(decoded['verb'], 'find');
    final results = (decoded['results'] as List).cast<Map<String, dynamic>>();
    expect(results, isNotEmpty);
    expect(results.first, contains('kind'));
    expect(results.first, contains('id'));
    expect(results.first, contains('inDeg'));
  });

  test('sym <Name> prints a symbol card with sig + members', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'sym',
      'FancyButton',
    ]);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('FancyButton  class'));
    expect(out, contains('class FancyButton'));
    expect(out, contains('members:'));
    expect(out, contains('press()'));
  });

  test(
      'sym <method> falls back to a class MEMBER when no top-level symbol '
      'matches', () {
    engine.build(const []);
    // m13 and render only exist as class members (ManyMembers.m13,
    // SamplePage.render) — before the member fallback, `sym` gave up with
    // "no symbol matches" even though `find`/`callers` already resolve them.
    // m13 is the 13th member of ManyMembers, past the 12-member display cap,
    // so it's only in the uncapped `memberIndex` (name + line, no full sig —
    // same data the "find matches members past the cap" test relies on).
    final m13 = Process.runSync('dart', [cliSnapshot, 'sym', 'm13']);
    expect(m13.exitCode, 0);
    final m13Out = m13.stdout as String;
    expect(m13Out, contains('member: ManyMembers.m13'));
    expect(m13Out, contains('lib/sig/many_members.dart:'));

    final render = Process.runSync('dart', [cliSnapshot, 'sym', 'render']);
    expect(render.exitCode, 0);
    final renderOut = render.stdout as String;
    expect(renderOut, contains('member: SamplePage.render'));
    expect(renderOut,
        contains('lib/features/sample/presentation/sample_page.dart:'));
    expect(renderOut, contains('void render()'));
  });

  test('sym <method> --json emits a member-kind record on the fallback path',
      () {
    engine.build(const []);
    final result =
        Process.runSync('dart', [cliSnapshot, 'sym', 'm13', '--json']);
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final results = (decoded['results'] as List).cast<Map<String, dynamic>>();
    expect(results, isNotEmpty);
    expect(results.first['kind'], 'member');
    expect(results.first['owner'], 'ManyMembers');
    expect(results.first['name'], 'm13');
    expect(results.first['file'], contains('lib/sig/many_members.dart'));
  });

  test(
      'sym <TopLevelSymbol> still resolves directly, unaffected by the '
      'member fallback', () {
    engine.build(const []);
    final result = Process.runSync('dart', [cliSnapshot, 'sym', 'FancyButton']);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('FancyButton  class'));
    expect(out, isNot(contains('member:')));
  });

  test(
      'brief <method> falls back to a class MEMBER when no top-level '
      'symbol matches', () {
    engine.build(const []);
    final result = Process.runSync('dart', [cliSnapshot, 'brief', 'm13']);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('member: ManyMembers.m13'));
  });

  test('wiring --json parses and contains expected sections', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'wiring',
      'home_page.dart',
      '--json',
    ]);
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(decoded['verb'], 'wiring');
    expect(decoded['watches'], contains('homeProvider'));
    expect(decoded['imports'], isA<List>());
  });

  test('skeleton <file> prints declarations with line numbers', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'skeleton',
      'home_page.dart',
    ]);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('home_page.dart'));
    expect(out, contains('class HomePage'));
    expect(out, contains('build(dynamic ref, dynamic context)'));
  });

  test('skeleton exits 1 when the resolved file is missing on disk', () {
    engine.build(const []);
    File('lib/home/home_page.dart').deleteSync();
    // --no-rebuild keeps the graph stale on purpose: the scenario under test
    // is "graph resolves the file, disk read fails". Without it the deletion
    // triggers the freshness auto-rebuild and the file is simply not found.
    final result = Process.runSync('dart', [
      cliSnapshot,
      'skeleton',
      'home_page.dart',
      '--no-rebuild',
    ]);
    expect(result.exitCode, 1);
  });

  test('brief <provider> prints the readers + declaring-file card', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'brief',
      'homeProvider',
    ]);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('provider homeProvider'));
    expect(out, contains('watches (1): lib/home/home_page.dart'));
    expect(out, contains('imported-by (1): lib/home/home_page.dart'));
  });

  test('brief <file> prints the file card with wiring both directions', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'brief',
      'home_page.dart',
    ]);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('lib/home/home_page.dart'));
    expect(out, contains('class HomePage'));
    expect(out, contains('watches (1): homeProvider:6'));
    // This fixture has no GoRoute table for '/details', so the nav is
    // genuinely unresolved (empirically verified) — inline render shows
    // '(unresolved)', not a resolved target.
    expect(out, contains("navigates (1): '/details':7 (unresolved)"));
  });

  test('brief <area> prints counts + top-10 sections', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'brief',
      'lib/home',
    ]);
    expect(result.exitCode, 0);
    final out = result.stdout as String;
    expect(out, contains('── lib/home  (6 files, 1 providers)'));
    expect(out, contains('providers by reader count:'));
    expect(out, contains('top files by in-degree:'));
  });

  test('brief <nonsense> exits 1 with a find hint', () {
    engine.build(const []);
    final result = Process.runSync('dart', [
      cliSnapshot,
      'brief',
      'zzzznonsensetoken',
    ]);
    expect(result.exitCode, 1);
    expect(result.stdout as String, contains('no match (graph fresh,'));
  });

  test(
    'passport prints a deterministic digest with the project name and the '
    'test-files count on the header line',
    () {
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'passport']);
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      expect(out, contains('project: fixture'));
      // 8 = 5 pre-existing Stage 3 test files + Stage 3b's
      // harness.dart/harness_part.dart pair + Stage B's
      // sample_controller_test.dart; see the testFiles comment above.
      expect(out, contains('/ 8 test files'));
      expect(out, contains('verbs:'));
    },
  );

  test(
    'area map has a Summary section (reader counts, entry pages, cross-area)',
    () {
      engine.build(const []);
      final md = File('docs/maps/home.md').readAsStringSync();
      expect(md, contains('## Summary'));
      // homeProvider is watched once (by home_page.dart) project-wide.
      expect(md, contains('Providers by reader count: homeProvider ·1'));
      // home_page.dart has role=view and a navigates edge.
      expect(md, contains('Entry pages: `home_page.dart`'));
      expect(md, contains('Cross-area providers consumed: (none)'));
    },
  );

  test(
    'area map is Summary-only: has the pointer line, and none of the '
    'deleted sections (providers/wiring/navigation/file inventory)',
    () {
      engine.build(const []);
      final md = File('docs/maps/home.md').readAsStringSync();
      expect(
        md,
        contains(
          '_Full detail: `codegraph brief lib/home` · `wiring <file>` '
          '· `sym <Symbol>` · `skeleton <file>`._',
        ),
      );
      expect(md, isNot(contains('## Providers declared here')));
      expect(md, isNot(contains('## Provider wiring')));
      expect(md, isNot(contains('## Cross-feature providers consumed')));
      expect(md, isNot(contains('## Navigation')));
      expect(md, isNot(contains('## File inventory')));
    },
  );

  test('INDEX.md has a ~tokens column formatted as X.Yk', () {
    engine.build(const []);
    final index = File('docs/maps/INDEX.md').readAsStringSync();
    expect(index, contains('| Area | files | providers | ~tokens | map |'));
    expect(
        RegExp(r'\| `lib/home` \| \d+ \| \d+ \| \d+\.\dk \|').hasMatch(index),
        isTrue);
    expect(index, contains('codegraph brief <area>` is the primary way'));
  });

  test('check() fails when committed docs/maps/ drifts from source', () {
    // git diff only sees *tracked* files, so docs/maps/ must be built and
    // committed once before drift can be detected (this mirrors check()'s
    // own documented behavior: untracked maps are ignored pre-first-commit).
    engine.build(const []);
    Process.runSync('git', ['init', '-q']);
    Process.runSync('git', ['add', '-A']);
    Process.runSync('git', [
      'commit',
      '-q',
      '-m',
      'fixture',
      '--author=test <test@example.com>',
    ]);

    // Committed maps match source: check() must pass.
    expect(engine.check(), 0);

    // Add an undeclared file the committed graph hasn't seen: check() must fail.
    File('lib/home/new_file.dart').writeAsStringSync('class NewThing {}\n');
    expect(engine.check(), 1);
  });

  test(
    'Graph.load().toJson() round-trips byte-identically to the graph file '
    'engine.build() wrote, including the 0.4.0 Stage 1 testRefs/testFiles '
    'fields and the Stage 4 navigates-to edge, at their pinned wire-format '
    'positions',
    () {
      engine.build(const []);
      final onDisk = File('docs/maps/code_graph.json').readAsBytesSync();

      // The fixture's test/home_test.dart references homeProvider (via a
      // resolved lib import) and testOnlyProvider (token match), so the
      // on-disk bytes must actually contain the new fields — this is not
      // just a byte-for-byte echo of whatever build() happened to write.
      final onDiskText = utf8.decode(onDisk);
      expect(onDiskText, contains('"testRefs"'));
      // 8 = home/barrel/chain/cycle/barrel_gated test files (Stage 3) + the
      // Stage 3b harness.dart/harness_part.dart pair (library + its part) +
      // Stage B's sample_controller_test.dart.
      expect(onDiskText, contains('"testFiles": 8'));
      // Stage 4: the fixture's details_caller.dart resolves, so the wire
      // format must actually carry a navigates-to edge (not just be
      // structurally capable of one).
      expect(onDiskText, contains('"rel": "navigates-to"'));
      expect(
          onDiskText, contains('"dst": "file:lib/routing/details_page.dart"'));

      // 0.7.0 Stage 1: imports edges carry `line` (the import directive's
      // 1-based line). home_page.dart imports home_provider.dart on line 2.
      final graph = Graph.load()!;
      final importEdge = graph.edges.singleWhere((e) =>
          e.rel == 'imports' &&
          e.src == 'file:lib/home/home_page.dart' &&
          e.dst == 'file:lib/home/home_provider.dart');
      expect(importEdge.line, 2);

      final reEncoded =
          const JsonEncoder.withIndent('  ').convert(graph.toJson());

      expect(utf8.encode(reEncoded), onDisk);
    },
  );

  test(
    'Stage 1: test scan sets testRefs on the home_provider file node and '
    'the homeProvider provider node, and stats.testFiles counts every '
    'scanned test file',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
      final stats = graph['stats'] as Map<String, dynamic>;

      // home_test.dart, barrel_test.dart, chain_test.dart, cycle_test.dart,
      // barrel_gated_test.dart (0.6.0 Stage 3 credited case), plus
      // harness.dart + harness_part.dart (0.6.0 Stage 3b part-file
      // inheritance — both the library and its part are separate physical
      // files and each increments testFileCount once). The Stage 3 negative
      // case (unreachableProvider) reuses home_test.dart's own comment
      // mention — no separate file needed for it. Stage B adds
      // sample_controller_test.dart → 8.
      expect(stats['testFiles'], 8);
      // testFiles is the LAST stats key (pinned wire-format position).
      expect(stats.keys.last, 'testFiles');
      // format is the FIRST stats key (0.6.0 Stage 1 pinned position).
      expect(stats.keys.first, 'format');
      expect(stats['format'], 6);

      final homeProviderFile = nodes.firstWhere(
        (n) => n['id'] == 'file:lib/home/home_provider.dart',
      );
      expect(homeProviderFile['testRefs'], 1);

      final homeProviderNode = nodes.firstWhere(
        (n) => n['kind'] == 'provider' && n['name'] == 'homeProvider',
      );
      expect(homeProviderNode['testRefs'], 1);

      // A provider only ever referenced from lib (never mentioned in test
      // source) omits testRefs entirely (0 is omitted, per the pinned
      // wire-format rule).
      final dupNodes = nodes.where(
        (n) => n['kind'] == 'provider' && n['name'] == 'dupProvider',
      );
      expect(dupNodes.every((n) => !n.containsKey('testRefs')), isTrue);
    },
  );

  test(
    'A.2: _scanTestRefs follows the export closure — a test importing an '
    'export-only barrel credits both the barrel and what it re-exports, a '
    'two-hop export chain credits the leaf, and a cyclic export pair '
    'terminates and credits both sides',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
      int testRefsOf(String path) {
        final n = nodes.firstWhere((n) => n['id'] == 'file:$path');
        return (n['testRefs'] as int?) ?? 0;
      }

      // Direct barrel: barrel_test.dart imports only barrel.dart, which
      // export-onlys impl.dart — both must be credited.
      expect(testRefsOf('lib/barrel/barrel.dart'), 1);
      expect(testRefsOf('lib/barrel/impl.dart'), 1);

      // Two-hop chain: chain_test.dart imports chain_top.dart ->
      // (export) chain_mid.dart -> (export) chain_leaf.dart.
      expect(testRefsOf('lib/barrel/chain_top.dart'), 1);
      expect(testRefsOf('lib/barrel/chain_mid.dart'), 1);
      expect(testRefsOf('lib/barrel/chain_leaf.dart'), 1);

      // Cyclic export pair: cycle_test.dart imports only cycle_a.dart,
      // which exports cycle_b.dart, which exports cycle_a.dart back — must
      // not hang, and must credit both.
      expect(testRefsOf('lib/barrel/cycle_a.dart'), 1);
      expect(testRefsOf('lib/barrel/cycle_b.dart'), 1);
    },
  );

  test(
    '0.6.0 Stage 3: a provider name mentioned in a test file that does NOT '
    'import its declaring file (directly or via a barrel) gets no testRefs '
    'credit at all, even though home_test.dart mentions the name in a '
    'comment',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();

      final unreachableNode = nodes.firstWhere(
        (n) => n['kind'] == 'provider' && n['name'] == 'unreachableProvider',
      );
      expect(unreachableNode.containsKey('testRefs'), isFalse);

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'untested', '--budget', '999'],
      );
      expect(result.stdout as String, contains('unreachableProvider'));
    },
  );

  test(
    '0.6.0 Stage 3: a provider name mentioned in a test file that imports '
    'its declaring file via a BARREL (export closure) gets credited',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();

      final barrelGatedNode = nodes.firstWhere(
        (n) => n['kind'] == 'provider' && n['name'] == 'barrelGatedProvider',
      );
      expect(barrelGatedNode['testRefs'], 1);

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'untested', '--budget', '999'],
      );
      expect(result.stdout as String, isNot(contains('barrelGatedProvider')));
    },
  );

  test(
    '0.6.0 Stage 3b: a provider referenced only inside a `part` file is '
    'credited via its parent library\'s imports (part files carry no '
    'imports of their own), and a sibling reference to a provider the '
    'parent does NOT import gets no credit',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();

      final inheritedNode = nodes.firstWhere(
        (n) => n['kind'] == 'provider' && n['name'] == 'partInheritedProvider',
      );
      expect(inheritedNode['testRefs'], 1);

      final notImportedNode = nodes.firstWhere(
        (n) =>
            n['kind'] == 'provider' && n['name'] == 'partNotImportedProvider',
      );
      expect(notImportedNode.containsKey('testRefs'), isFalse);

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'untested', '--budget', '999'],
      );
      expect(
        result.stdout as String,
        isNot(contains('partInheritedProvider')),
      );
      expect(result.stdout as String, contains('partNotImportedProvider'));
    },
  );

  test(
    'untested lists the un-referenced provider (dupProvider) and view file, '
    'and NOT homeProvider or testOnlyProvider (both have a test reference)',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'untested', '--budget', '999'],
      );
      expect(result.exitCode, 0);
      final out = result.stdout as String;

      expect(out, contains('providers with zero test references'));
      expect(out, isNot(contains('homeProvider')));
      expect(out, isNot(contains('testOnlyProvider')));
      // dupProvider is never mentioned in test/home_test.dart's source.
      expect(out, contains('dupProvider'));

      expect(out, contains('files with zero test references'));
      expect(out, contains('untested_area/untested_view_page.dart'));
      expect(out, isNot(contains('home/home_provider.dart')));
    },
  );

  test('untested --json parses and reports zero-testRef providers/files', () {
    engine.build(const []);
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'untested', '--json', '--budget', '999'],
    );
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(decoded['verb'], 'untested');
    final providers =
        (decoded['providers'] as List).cast<Map<String, dynamic>>();
    expect(providers.any((p) => p['name'] == 'dupProvider'), isTrue);
    expect(providers.any((p) => p['name'] == 'homeProvider'), isFalse);
    expect(providers.any((p) => p['name'] == 'testOnlyProvider'), isFalse);
    final files = (decoded['files'] as List).cast<Map<String, dynamic>>();
    expect(
      files.any(
        (f) => f['file'] == 'lib/untested_area/untested_view_page.dart',
      ),
      isTrue,
    );
  });

  test(
    'impact <provider> depth 1 reaches the direct reader (home_page.dart), '
    'a page, and is not reached by the two-hop chain beyond it',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'homeProvider', '--depth', '1'],
      );
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      expect(out, contains('impact of homeProvider  (depth 1)'));
      expect(out, contains('depth 1 (1):'));
      expect(out, contains('lib/home/home_page.dart'));
      expect(out, contains('affected: 1 files (1 pages) at depth<=1'));
      expect(out, isNot(contains('home_page_importer.dart')));
    },
  );

  test(
    'impact <file> depth 2 reaches the second-level importer, depth 1 does '
    'not',
    () {
      engine.build(const []);
      final depth1 = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'home_page.dart', '--depth', '1'],
      );
      expect(depth1.exitCode, 0);
      final depth1Out = depth1.stdout as String;
      expect(depth1Out, contains('lib/impact_area/home_page_importer.dart'));
      expect(depth1Out, isNot(contains('home_page_reimporter.dart')));

      final depth2 = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'home_page.dart', '--depth', '2'],
      );
      expect(depth2.exitCode, 0);
      final out = depth2.stdout as String;
      expect(out, contains('impact of home_page.dart  (depth 2)'));
      expect(out, contains('depth 2 (1):'));
      expect(out, contains('home_page_reimporter.dart'));
      expect(out, contains('affected: 2 files (0 pages) at depth<=2'));
    },
  );

  test('impact --json parses with levels arrays', () {
    engine.build(const []);
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'impact', 'home_page.dart', '--depth', '2', '--json'],
    );
    expect(result.exitCode, 0);
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(decoded['verb'], 'impact');
    expect(decoded['depth'], 2);
    final summary = decoded['summary'] as Map<String, dynamic>;
    expect(summary['files'], 2);
    final levels = (decoded['levels'] as List).cast<List<dynamic>>();
    expect(levels, hasLength(2));
    expect(
      (levels[0].single as Map<String, dynamic>)['file'],
      'lib/impact_area/home_page_importer.dart',
    );
    expect(
      (levels[1].single as Map<String, dynamic>)['file'],
      'lib/impact_area/home_page_reimporter.dart',
    );
  });

  test(
    'impact --depth above 5 clamps to 5 and, in --json mode, carries the '
    'original requestedDepth alongside the clamped depth',
    () {
      engine.build(const []);
      final textResult = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'home_page.dart', '--depth', '9'],
      );
      expect(textResult.exitCode, 0);
      expect(textResult.stdout as String, contains('depth 9 capped at 5'));

      final jsonResult = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'home_page.dart', '--depth', '9', '--json'],
      );
      expect(jsonResult.exitCode, 0);
      final decoded =
          jsonDecode(jsonResult.stdout as String) as Map<String, dynamic>;
      expect(decoded['depth'], 5);
      expect(decoded['requestedDepth'], 9);

      // No clamp -> no requestedDepth key at all.
      final unclamped = jsonDecode(
        Process.runSync(
          'dart',
          [cliSnapshot, 'impact', 'home_page.dart', '--depth', '2', '--json'],
        ).stdout as String,
      ) as Map<String, dynamic>;
      expect(unclamped.containsKey('requestedDepth'), isFalse);
    },
  );

  test('impact <nonsense> exits 1', () {
    engine.build(const []);
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'impact', 'zzzznonsensetoken'],
    );
    expect(result.exitCode, 1);
    expect(result.stdout as String, contains('no match (graph fresh,'));
  });

  test(
    'impact <ambiguous dupProvider> unions readers from both declarations',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'impact', 'dupProvider', '--depth', '1'],
      );
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      expect(out, contains('depth 1 (2):'));
      expect(out, contains('lib/dup/a_reader.dart'));
      expect(out, contains('lib/dup/b_reader.dart'));
    },
  );

  test('find with two terms hits FancyButton (tokenized match)', () {
    engine.build(const []);
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'find', 'fancy', 'button'],
    );
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('FancyButton'));
  });

  test('find with a term that matches nothing reports no matches', () {
    engine.build(const []);
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'find', 'fancy', 'zzz'],
    );
    expect(result.exitCode, 0);
    // Typed empty (0.10): freshness stated, plus the verb's scope caveat.
    expect(result.stdout as String, contains('no matches (graph fresh,'));
    expect(result.stdout as String, contains('caveat:'));
  });

  test(
      '0.10 typed empties: impls distinguishes "no subtypes" from '
      '"no such type"; readers/callers not-found state freshness', () {
    engine.build(const []);
    String out(List<String> args) =>
        Process.runSync('dart', [cliSnapshot, ...args]).stdout as String;

    // HomePage exists but nothing extends it -> a real answer, not absence.
    expect(out(['impls', 'HomePage']), contains('no subtypes - HomePage is '));
    // A nonsense type -> absence, stated against a fresh graph.
    expect(out(['impls', 'ZzzNoSuchType']),
        contains('no such type - graph fresh,'));
    expect(out(['readers', 'zzzNoSuchProvider']), contains('(graph fresh,'));
    expect(out(['callers', 'zzzNoSuchFn']), contains('graph fresh,'));
  });

  test(
      '0.10 JSON envelope: query verbs carry fresh + caveats additively '
      '(existing keys untouched)', () {
    engine.build(const []);
    Map<String, dynamic> json(List<String> args) => jsonDecode(
        Process.runSync('dart', [cliSnapshot, ...args, '--json']).stdout
            as String) as Map<String, dynamic>;

    final readers = json(['readers', 'homeProvider']);
    expect(readers['fresh'], isTrue);
    expect(readers['caveats'], isNotEmpty);
    expect(readers['results'], isNotEmpty); // pre-envelope key still present

    final find = json(['find', 'HomePage']);
    expect(find['fresh'], isTrue);
    expect(find['caveats'], isNotEmpty);
    expect(find['results'], isNotEmpty);
  });

  test('disclosure caveats: readers discloses ProviderScope overrides', () {
    // Guards the 2.0 disclosure against being dropped in a caveat rewrite.
    expect(
        cli_util.verbCaveats['readers']!.join(' '), contains('ProviderScope'));
    expect(cli_util.verbCaveats['provider']!.join(' '), contains('family'));
    expect(cli_util.verbCaveats['callers']!.join(' '), contains('same-named'));
    expect(cli_util.verbCaveats['refs']!.join(' '), contains('same-named'));
    expect(cli_util.verbCaveats['untested']!.join(' '), contains('credit'));
  });

  test(
      'callers --json flags a name with multiple declarations via '
      'ambiguousDeclarations', () {
    engine.build(const []);
    Map<String, dynamic> json(List<String> args) => jsonDecode(
        Process.runSync('dart', [cliSnapshot, ...args, '--json']).stdout
            as String) as Map<String, dynamic>;

    // chainDupTarget is declared twice in the fixture (Batch B ambiguity).
    final dup = json(['callers', 'chainDupTarget']);
    expect((dup['declarations'] as List).length, 2);
    expect(dup['ambiguousDeclarations'], 2);

    // Single declaration: the key stays absent (additive, not noise).
    final single = json(['callers', 'formatHomeTitle']);
    expect((single['declarations'] as List).length, 1);
    expect(single.containsKey('ambiguousDeclarations'), isFalse);
  });

  test(
    'find single-term stdout is byte-identical to the pre-Stage-2 expected '
    'lines (tokenized path only activates for >1 term)',
    () {
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'find', 'home']);
      expect(result.exitCode, 0);
      final lines = (result.stdout as String)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      final helperIdx = lines.indexWhere((l) => l.contains('home_helper.dart'));
      final orphanIdx = lines.indexWhere(
        (l) => l.contains('home_zzz_orphan.dart'),
      );
      expect(helperIdx, greaterThanOrEqualTo(0));
      expect(orphanIdx, greaterThanOrEqualTo(0));
      expect(helperIdx, lessThan(orphanIdx));
      expect(lines[helperIdx], contains('·2⇐'));
      final symbolLine = lines.firstWhere(
        (l) => l.startsWith('symbol: formatHomeTitle'),
      );
      expect(symbolLine, contains(':2'));
    },
  );

  test(
    'unused providers + ATTENTION.md tag testOnlyProvider with the '
    '· test-only (N test refs) suffix (zero lib consumers, one test ref)',
    () {
      engine.build(const []);
      final unusedResult = Process.runSync(
        'dart',
        [cliSnapshot, 'unused', 'providers', '--budget', '999'],
      );
      expect(unusedResult.exitCode, 0);
      expect(
        unusedResult.stdout as String,
        contains('testOnlyProvider — Provider — '
            'lib/testonly/testonly_provider.dart · test-only (1 test refs)'),
      );

      final md = File('docs/maps/ATTENTION.md').readAsStringSync();
      expect(md, contains('testOnlyProvider'));
      expect(md, contains('· test-only (1 test refs)'));
    },
  );

  test(
    'build() writes ATTENTION.md with ambiguous providers + zero-consumer/'
    'orphan sections, and never the verb-only stale-notes section',
    () {
      engine.build(const []);
      final md = File('docs/maps/ATTENTION.md').readAsStringSync();

      expect(md, contains('# ATTENTION'));
      expect(md, contains('## Ambiguous providers'));
      expect(md, contains('dupProvider'));
      expect(md, contains('## Providers with zero consumers'));
      expect(md, contains('## Files nothing imports'));
      // home_zzz_orphan is a known orphan. Assert DETECTION (uncapped), not its
      // presence in the rendered section: that section caps at 20 for display,
      // and this fixture has >20 genuine orphans, so a late-sorting file can
      // fall past the cap. What matters is that orphan detection flags it.
      expect(
        Graph.load()!.orphanFiles.map((n) => n.id),
        contains('file:lib/home/home_zzz_orphan.dart'),
      );
      expect(md, contains('## Duplicate symbol names'));
      expect(md, contains('## Unresolved navigation'));
      expect(md, isNot(contains('Possibly stale')));
    },
  );

  test(
    'ATTENTION.md\'s Unresolved navigation section omits a navigates edge '
    'that Stage 4 already resolved to a navigates-to edge',
    () {
      engine.build(const []);
      final md = File('docs/maps/ATTENTION.md').readAsStringSync();
      final section = md.substring(
        md.indexOf('## Unresolved navigation'),
        md.indexOf('## ', md.indexOf('## Unresolved navigation') + 1) == -1
            ? md.length
            : md.indexOf(
                '## ',
                md.indexOf('## Unresolved navigation') + 1,
              ),
      );
      // details_caller.dart's context.go(AppPaths.details.path) resolves to
      // a navigates-to edge (see the Stage 4 fixtures) — must not show up
      // here even though its raw navigates target isn't a string literal.
      expect(section, isNot(contains('details_caller.dart')));
      // wrapped_caller.dart's call is genuinely unresolved (the GoRoute's
      // builder is a wrapper, see engine.dart's never-guess fix) — still
      // listed.
      expect(section, contains('wrapped_caller.dart'));
    },
  );

  test(
    'ATTENTION.md\'s Unresolved navigation section still surfaces a '
    'genuinely-unresolved nav even when it shares a physical line with a '
    'resolvable nav (the (src, line) join used to swallow it)',
    () {
      engine.build(const []);
      final md = File('docs/maps/ATTENTION.md').readAsStringSync();
      final start = md.indexOf('## Unresolved navigation');
      final nextHeader = md.indexOf('## ', start + 1);
      final section =
          md.substring(start, nextHeader == -1 ? md.length : nextHeader);
      expect(section, contains('collision_caller.dart'));
    },
  );

  test('codegraph attention exits 0 and reports dupProvider', () {
    engine.build(const []);
    final result = Process.runSync('dart', [cliSnapshot, 'attention']);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('dupProvider'));
    expect(result.stdout as String, isNot(contains('Possibly stale')));
  });

  test(
    'attention skips the stale-notes check silently when git is not on '
    'PATH (does not throw ProcessException)',
    () {
      engine.build(const []);
      Directory('docs/maps/notes').createSync(recursive: true);
      File('docs/maps/notes/home.md').writeAsStringSync('# home notes\n');

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'attention'],
        environment: {'PATH': gitlessPath},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, isNot(contains('Possibly stale')));
    },
  );

  test(
    'init writes scaffolding when git is not on PATH (migration-hint check '
    "doesn't throw ProcessException)",
    () {
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'init'],
        environment: {'PATH': gitlessPath},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(File('CLAUDE.md').existsSync(), isTrue);
      expect(File('.gitignore').readAsStringSync(),
          contains('docs/maps/code_graph.json'));
    },
  );

  test(
    'init writes docs/maps/code_graph.json into .gitignore, idempotently',
    () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      final gitignore = File('.gitignore').readAsStringSync();
      expect(gitignore, contains('docs/maps/code_graph.json'));

      final result = Process.runSync('dart', [
        cliSnapshot,
        'init',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('skip'));
      expect(result.stdout as String, contains('.gitignore'));
      // Still exactly one entry — not duplicated.
      final lines = File('.gitignore')
          .readAsStringSync()
          .split('\n')
          .where((l) => l.trim() == 'docs/maps/code_graph.json');
      expect(lines.length, 1);
    },
  );

  test(
    'init writes .cursor/rules/codegraph.mdc when .cursor/ exists, with the '
    'same command block as the CLAUDE.md block, and skips on rerun',
    () {
      Directory('.cursor').createSync();
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');

      final mdc = File('.cursor/rules/codegraph.mdc').readAsStringSync();
      expect(mdc, startsWith('---\n'));
      expect(
          mdc, contains('description: Query the code graph before grepping'));
      expect(mdc, contains('alwaysApply: true'));
      expect(mdc, contains('codegraph brief <thing>'));
      expect(mdc, contains('codegraph path <A> <B>'));

      // Same command-list body as the CLAUDE.md block — single shared source.
      final claudeMd = File('CLAUDE.md').readAsStringSync();
      expect(claudeMd, contains('codegraph brief <thing>'));
      expect(mdc, contains('codegraph readers <provider>'));
      expect(claudeMd, contains('codegraph readers <provider>'));

      final result = Process.runSync('dart', [cliSnapshot, 'init']);
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('skip'));
      expect(result.stdout as String, contains('.cursor/rules/codegraph.mdc'));
    },
  );

  test(
    'init does NOT write .cursor/rules/codegraph.mdc when .cursor/ is '
    'absent and --cursor was not passed',
    () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      expect(File('.cursor/rules/codegraph.mdc').existsSync(), isFalse);
    },
  );

  test(
    'determinism: build() twice in a row produces byte-identical '
    'ATTENTION.md',
    () {
      engine.build(const []);
      final first = File('docs/maps/ATTENTION.md').readAsBytesSync();
      engine.build(const []);
      final second = File('docs/maps/ATTENTION.md').readAsBytesSync();
      expect(second, first);
    },
  );

  test(
    'determinism lock: build() twice in a row produces the same file set '
    'and byte-identical content for EVERY file under docs/maps/ (excluding '
    'docs/maps/notes/)',
    () {
      engine.build(const []);
      final before = _snapshotMaps();
      engine.build(const []);
      final after = _snapshotMaps();

      expect(after.keys.toSet(), before.keys.toSet());
      for (final path in before.keys) {
        expect(after[path], before[path], reason: '$path changed on rebuild');
      }
    },
  );

  test(
    'brief <area> appends a notes section (first 20 lines + more-lines '
    'marker), and a small --budget still caps the total',
    () {
      engine.build(const []);
      final noteFile = File('docs/maps/notes/home.md');
      noteFile.parent.createSync(recursive: true);
      noteFile.writeAsStringSync(
        List.generate(25, (i) => 'note line $i').join('\n'),
      );

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'brief', 'lib/home', '--budget', '999'],
      );
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      expect(out, contains('notes (docs/maps/notes/home.md):'));
      expect(out, contains('… 5 more lines — read the file'));

      final capped = Process.runSync(
        'dart',
        [cliSnapshot, 'brief', 'lib/home', '--budget', '3'],
      );
      expect(capped.exitCode, 0);
      final cappedLines =
          (capped.stdout as String).split('\n').where((l) => l.isNotEmpty);
      // 3 body lines + the "… N more (raise --budget N)" + hint trailer.
      expect(cappedLines.length, lessThanOrEqualTo(5));
    },
  );

  test(
    'brief <file> appends "area notes exist" when the file\'s area has a '
    'note',
    () {
      engine.build(const []);
      final noteFile = File('docs/maps/notes/home.md');
      noteFile.parent.createSync(recursive: true);
      noteFile.writeAsStringSync('a couple lines of context\n');

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'brief', 'home_page.dart'],
      );
      expect(result.exitCode, 0);
      expect(
        result.stdout as String,
        contains('area notes exist: docs/maps/notes/home.md'),
      );
    },
  );

  test('passport lists notes dir contents', () {
    engine.build(const []);
    final noteFile = File('docs/maps/notes/home.md');
    noteFile.parent.createSync(recursive: true);
    noteFile.writeAsStringSync('note\n');

    final result = Process.runSync('dart', [cliSnapshot, 'passport']);
    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('notes: home'));
  });

  test('build() does not modify or delete docs/maps/notes/', () {
    engine.build(const []);
    final noteFile = File('docs/maps/notes/home.md');
    noteFile.parent.createSync(recursive: true);
    noteFile.writeAsStringSync('untouched by build\n');
    final before = noteFile.readAsBytesSync();

    engine.build(const []);

    expect(noteFile.existsSync(), isTrue);
    expect(noteFile.readAsBytesSync(), before);
  });

  test(
    'attention verb reports "Possibly stale notes" for a note older than a '
    'later change to its area; the committed ATTENTION.md never does',
    () {
      engine.build(const []);
      Process.runSync('git', ['init', '-q']);
      Process.runSync('git', ['config', 'user.email', 'test@example.com']);
      Process.runSync('git', ['config', 'user.name', 'test']);

      final noteFile = File('docs/maps/notes/home.md');
      noteFile.parent.createSync(recursive: true);
      noteFile.writeAsStringSync('home area context\n');
      Process.runSync('git', ['add', '-A']);
      // Explicit, 1-hour-apart commit dates (not wall-clock `sleep`) so the
      // note-vs-area ordering is deterministic regardless of test speed.
      Process.runSync(
        'git',
        [
          'commit',
          '-q',
          '-m',
          'seed + note',
          '--author=test <test@example.com>',
          '--date=2026-01-01T00:00:00',
        ],
        environment: {'GIT_COMMITTER_DATE': '2026-01-01T00:00:00'},
      );

      // Modify + commit a lib/home file AFTER the note — the area is now
      // newer than the note.
      File('lib/home/home_zzz_orphan.dart')
          .writeAsStringSync('class HomeZzzOrphan {}\n// touched\n');
      Process.runSync('git', ['add', '-A']);
      Process.runSync(
        'git',
        [
          'commit',
          '-q',
          '-m',
          'touch home area',
          '--author=test <test@example.com>',
          '--date=2026-01-01T01:00:00',
        ],
        environment: {'GIT_COMMITTER_DATE': '2026-01-01T01:00:00'},
      );

      engine.build(const []);
      final result = Process.runSync(
          'dart', [cliSnapshot, 'attention', '--budget', '999']);
      expect(result.exitCode, 0);
      final out = result.stdout as String;
      expect(out, contains('Possibly stale notes'));
      expect(out, contains('docs/maps/notes/home.md'));

      final md = File('docs/maps/ATTENTION.md').readAsStringSync();
      expect(md, isNot(contains('Possibly stale')));
    },
  );

  // --- Stage 3: diff verb -------------------------------------------------

  test(
    'diff --base main reports header counts, deleted-but-imported, '
    'changed-but-untested, and " (new)" on an added provider',
    () {
      engine.build(const []);
      Process.runSync('git', ['init', '-q', '-b', 'main']);
      Process.runSync('git', ['config', 'user.email', 'test@example.com']);
      Process.runSync('git', ['config', 'user.name', 'test']);
      Process.runSync('git', ['add', '-A']);
      Process.runSync('git', [
        'commit',
        '-q',
        '-m',
        'base',
        '--author=test <test@example.com>',
      ]);

      // Modify a lib file already in the graph (role=view via `_page.dart`).
      File('lib/home/home_page.dart').writeAsStringSync('''
import 'package:fixture_ui/fancy_button.dart';
import 'package:fixture/home/home_provider.dart';

class HomePage {
  void build(dynamic ref, dynamic context) {
    ref.watch(homeProvider);
    context.go('/details');
    FancyButton();
    // touched
  }
}
''');

      // Add a brand-new provider file.
      File('lib/diffnew/diff_new_provider.dart')
          .parent
          .createSync(recursive: true);
      File('lib/diffnew/diff_new_provider.dart').writeAsStringSync(
        'final diffNewProvider = Provider<int>((ref) => 1);\n',
      );

      // Delete a file another lib file imports (home_helper.dart, imported by
      // home_reader_a.dart and home_reader_b.dart).
      File('lib/home/home_helper.dart').deleteSync();

      // `git diff <ref>` (no --cached) is blind to untracked files — stage
      // the new file so it shows up as an 'A' line, same as a real PR branch
      // where the new file has already been committed.
      Process.runSync('git', ['add', '-A']);

      // A SECOND new provider file, deliberately left untracked (no `git
      // add`) — the `git ls-files --others --exclude-standard` pass must
      // still surface it as an 'A' line, since `git diff` alone is blind to
      // it.
      File('lib/diffnew/diff_untracked_provider.dart').writeAsStringSync(
        'final diffUntrackedProvider = Provider<int>((ref) => 1);\n',
      );

      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main', '--budget', '999'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;

      expect(out, startsWith('diff vs main (merge-base '));
      // 4 lib files changed (home_page.dart modified, diff_new_provider.dart
      // added + staged, diff_untracked_provider.dart added + untracked,
      // home_helper.dart deleted) · 0 test files.
      expect(out, contains('4 dart files changed (4 lib · 0 test)'));

      expect(out, contains('deleted but still imported:'));
      expect(out, contains('lib/home/home_helper.dart'));

      expect(out, contains('changed but untested:'));
      expect(out, contains('lib/home/home_page.dart'));
      expect(out, contains('lib/diffnew/diff_untracked_provider.dart'));

      expect(out, contains('diffNewProvider'));
      expect(out, contains('diffUntrackedProvider'));
      expect(out, contains('(new)'));
    },
  );

  test('diff --json parses and carries base/mergeBase/files', () {
    engine.build(const []);
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'test@example.com']);
    Process.runSync('git', ['config', 'user.name', 'test']);
    Process.runSync('git', ['add', '-A']);
    Process.runSync('git', [
      'commit',
      '-q',
      '-m',
      'base',
      '--author=test <test@example.com>',
    ]);

    File('lib/home/home_zzz_orphan.dart')
        .writeAsStringSync('class HomeZzzOrphan {}\n// touched\n');

    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'diff', '--base', 'main', '--json'],
    );
    expect(result.exitCode, 0, reason: result.stderr as String);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['verb'], 'diff');
    expect(json['base'], 'main');
    expect(json['mergeBase'], isNotEmpty);
    expect((json['files'] as Map)['lib'], 1);
    expect((json['files'] as Map)['test'], 0);
  });

  test(
      'diff --json caps each section INDEPENDENTLY — a tiny --budget does not '
      'starve the later (decision-relevant) sections to []', () {
    engine.build(const []);
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'test@example.com']);
    Process.runSync('git', ['config', 'user.name', 'test']);
    Process.runSync('git', ['add', '-A']);
    Process.runSync('git', [
      'commit',
      '-q',
      '-m',
      'base',
      '--author=test <test@example.com>',
    ]);
    // A NEW untested view file (role=view via _page.dart, no test) — lands in
    // both areasTouched (early section) AND changedButUntested (late section).
    File('lib/diffbudget/new_orphan_page.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class NewOrphanPage {}\n');
    engine.build(const []);

    // --budget 1: with the old shared budget, areasTouched consumes it and
    // changedButUntested is []. With independent caps it still gets its item.
    final result = Process.runSync('dart',
        [cliSnapshot, 'diff', '--base', 'main', '--json', '--budget', '1']);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect((json['areasTouched'] as List), isNotEmpty);
    expect((json['changedButUntested'] as List), isNotEmpty,
        reason: 'a late section must not be starved by an early one');
    expect((json['changedButUntested'] as List).first['file'],
        'lib/diffbudget/new_orphan_page.dart');
  });

  test(
    'diff exits 1 with a one-line error (no crash) when git is not on PATH',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main'],
        environment: {'PATH': gitlessPath},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 1);
      expect((result.stderr as String).trim().split('\n'), hasLength(1));
      expect(result.stderr as String, contains('git not found on PATH'));
    },
  );

  test(
    'diff with no --base and git not on PATH reports "git not found on '
    'PATH" (not the no-base hint — the auto-base lookup itself failed to '
    'run, it did not just fail to find a candidate ref)',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'diff'],
        environment: {'PATH': gitlessPath},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 1);
      expect((result.stderr as String).trim().split('\n'), hasLength(1));
      expect(result.stderr as String, contains('git not found on PATH'));
      expect(result.stderr as String, isNot(contains('no base found')));
    },
  );

  test('diff with no changes vs base prints the single no-changes line', () {
    engine.build(const []);
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'test@example.com']);
    Process.runSync('git', ['config', 'user.name', 'test']);
    Process.runSync('git', ['add', '-A']);
    Process.runSync('git', [
      'commit',
      '-q',
      '-m',
      'base',
      '--author=test <test@example.com>',
    ]);

    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'diff', '--base', 'main'],
    );
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect((result.stdout as String).trim(), 'no dart changes vs main');
  });

  // --- 0.7.0 Stage 3: diff card reuses lint --------------------------------

  test(
    'diff card appends a lint line when a NEW (non-baselined) violation '
    'exists — the fixture\'s cross-feature-import fires by default',
    () {
      engine.build(const []);
      Process.runSync('git', ['init', '-q', '-b', 'main']);
      Process.runSync('git', ['config', 'user.email', 'test@example.com']);
      Process.runSync('git', ['config', 'user.name', 'test']);
      Process.runSync('git', ['add', '-A']);
      Process.runSync('git', [
        'commit',
        '-q',
        '-m',
        'base',
        '--author=test <test@example.com>',
      ]);
      File('lib/home/home_zzz_orphan.dart')
          .writeAsStringSync('class HomeZzzOrphan {}\n// touched\n');
      engine.build(const []);

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(
          out,
          matches(RegExp(
              r'lint: \d+ new architecture violation\(s\) — codegraph lint')));

      final jsonResult = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main', '--json'],
      );
      final json =
          jsonDecode(jsonResult.stdout as String) as Map<String, dynamic>;
      expect(json['lintNewViolations'], greaterThan(0));
    },
  );

  test(
    'diff card omits the lint line entirely once all violations are '
    'baselined',
    () {
      engine.build(const []);
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);
      Process.runSync('git', ['init', '-q', '-b', 'main']);
      Process.runSync('git', ['config', 'user.email', 'test@example.com']);
      Process.runSync('git', ['config', 'user.name', 'test']);
      Process.runSync('git', ['add', '-A']);
      Process.runSync('git', [
        'commit',
        '-q',
        '-m',
        'base',
        '--author=test <test@example.com>',
      ]);
      File('lib/home/home_zzz_orphan.dart')
          .writeAsStringSync('class HomeZzzOrphan {}\n// touched\n');
      engine.build(const []);

      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, isNot(contains('lint:')));

      final jsonResult = Process.runSync(
        'dart',
        [cliSnapshot, 'diff', '--base', 'main', '--json'],
      );
      final json =
          jsonDecode(jsonResult.stdout as String) as Map<String, dynamic>;
      expect(json.containsKey('lintNewViolations'), isFalse);
    },
  );

  // --- Stage 4: navigation resolution -------------------------------------

  test(
    'build() resolves a context.go(AppPaths.<chain>.path) call to the '
    'GoRoute\'s builder page file via a navigates-to edge, immediately '
    'after the raw navigates edge, and prints the nav resolution metric',
    () {
      final result = Process.runSync('dart', [cliSnapshot, 'build']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stderr as String,
        contains(RegExp(r'nav resolution: \d+/\d+ navigate edges resolved')),
      );

      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/details_caller.dart')
          .toList();
      final navIdx = callerEdges.indexWhere((e) => e['rel'] == 'navigates');
      final navToIdx = callerEdges.indexWhere(
        (e) => e['rel'] == 'navigates-to',
      );
      expect(navIdx, greaterThanOrEqualTo(0));
      expect(navToIdx, navIdx + 1,
          reason: 'navigates-to must follow navigates immediately');
      expect(
        callerEdges[navToIdx]['dst'],
        'file:lib/routing/details_page.dart',
      );
      expect(callerEdges[navToIdx]['line'], callerEdges[navIdx]['line']);

      // The unresolvable local-variable caller gets a plain navigates edge
      // and NO navigates-to edge — never guessed.
      final dynamicEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/dynamic_caller.dart')
          .toList();
      expect(dynamicEdges.where((e) => e['rel'] == 'navigates'), hasLength(1));
      expect(dynamicEdges.where((e) => e['rel'] == 'navigates-to'), isEmpty);

      // Wrapped-builder regression (never-guess doctrine): the GoRoute's
      // builder top-level call is `AnalyticsWrapper(child: WrappedPage())` —
      // not a bare page constructor — so a path-matching caller must get a
      // plain navigates edge and NO navigates-to edge, and wrapped_page.dart
      // must not appear as any navigates-to target at all.
      final wrappedCallerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/wrapped_caller.dart')
          .toList();
      expect(
        wrappedCallerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        wrappedCallerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
      expect(
        edges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/wrapped_page.dart',
        ),
        isEmpty,
      );
    },
  );

  test(
    '0.6.0 Stage 1: navigates edges carry `unresolved: true` only when no '
    'sibling navigates-to edge was emitted',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final resolvedNav = edges.firstWhere(
        (e) =>
            e['src'] == 'file:lib/routing/details_caller.dart' &&
            e['rel'] == 'navigates',
      );
      expect(resolvedNav.containsKey('unresolved'), isFalse);

      final unresolvedNav = edges.firstWhere(
        (e) =>
            e['src'] == 'file:lib/routing/dynamic_caller.dart' &&
            e['rel'] == 'navigates',
      );
      expect(unresolvedNav['unresolved'], true);
    },
  );

  // --- 0.5.0 mechanism (a): route-constant substitution -------------------

  test(
    'mechanism (a): a route constant (`final constantRoute = '
    'AppPaths.constant;`) used on both the GoRoute path and a caller '
    'resolves via the constant table',
    () {
      final result = Process.runSync('dart', [cliSnapshot, 'build']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/constant_caller.dart')
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/constant_page.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'mechanism (a) REFUSAL: a constant name declared twice with different '
    'chains is dropped from the table — its caller gets no navigates-to',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/dup_const_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'mechanism (a): a constant-of-constant (2-hop: hopB = hopA; hopA = '
    'AppPaths.constant;) resolves within the depth-3 cap',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/two_hop_caller.dart')
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/constant_page.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'mechanism (a) REFUSAL: a 4-hop constant-of-constant chain (beyond the '
    'depth-3 cap) never resolves',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/four_hop_caller.dart')
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  // --- 0.5.0 shadowing / reachability gate -----------------

  test(
    'REFUSAL: a local PARAMETER named like a distant constant '
    'shadows it — no navigates-to, even though the constant is reachable',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/shadow_param_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'REFUSAL: a local VARIABLE named like a distant constant '
    'shadows it — no navigates-to',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/shadow_local_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'REFUSAL: a constant whose declaring file is not '
    'import-reachable from the reader never resolves',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/unreachable_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'a file using its OWN constant still resolves — the '
    'self-reference exception to the shadowing gate',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/self_const_caller.dart')
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/self_const_page.dart',
        ),
        hasLength(1),
      );
    },
  );

  // --- 0.5.0 cross-file constant identity ------------------

  test(
    'two same-name/same-text constants in different files — a '
    'caller reachable from only ONE resolves',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) =>
                e['src'] ==
                'file:lib/routing/same_text_single_reach_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/constant_page.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'REFUSAL: two same-name/same-text constants in different '
    'files — a caller reachable from BOTH refuses (file identity, not text, '
    'disambiguates)',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) =>
                e['src'] == 'file:lib/routing/same_text_both_reach_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  // --- 0.5.0 mechanism (b): monomorphic helper inlining --------------------

  test(
    'mechanism (b): a route helper function called from EXACTLY ONE call '
    'site project-wide is inlined, resolving its GoRoute path',
    () {
      final result = Process.runSync('dart', [cliSnapshot, 'build']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) =>
                e['src'] == 'file:lib/routing/single_site_helper_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/helper_page.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'mechanism (b) REFUSAL: a SECOND call site to the same helper function '
    'drops the resolution entirely, even though the first call site alone '
    'would have resolved',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/two_site_helper_caller_a.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
      expect(
        edges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/helper_page.dart' &&
              e['src'] == 'file:lib/routing/two_site_helper_caller_a.dart',
        ),
        isEmpty,
      );
    },
  );

  test(
    'mechanism (b) REFUSAL: a helper called with a NAMED argument (instead '
    'of positional) never resolves, even with a single call site',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/named_arg_helper_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  // --- 0.5.0 helper-declaration-identity + tear-off gate ----

  test(
    'REFUSAL: two DIFFERENT top-level functions sharing the same '
    'name — neither resolves, even the one with a single legitimate call '
    'site',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/dup_helper_decl_a_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'REFUSAL: a single-declaration, single-call-site helper whose '
    'name is also referenced (torn off) from a THIRD file never resolves',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/tearoff_helper_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  // --- 0.5.0 mechanism (c): wrapper allowlist + goNamed --------------------

  test(
    'mechanism (c): an allowlisted pageBuilder wrapper '
    '(MaterialPage(child: Foo())) resolves to the child page, unlike a '
    'project-declared wrapper',
    () {
      final result = Process.runSync('dart', [cliSnapshot, 'build']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/material_page_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/material_page_target.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'mechanism (c): wrapper-in-wrapper within the allowlist '
    '(MaterialPage(child: CustomTransitionPage(child: Foo()))) resolves to '
    'the innermost page',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where(
            (e) => e['src'] == 'file:lib/routing/nested_wrapper_caller.dart',
          )
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/nested_wrapper_target.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'mechanism (c) REGRESSION: a project-declared wrapper '
    '(AnalyticsWrapper, not on the allowlist) still refuses entirely',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final wrappedCallerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/wrapped_caller.dart')
          .toList();
      expect(
        wrappedCallerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'mechanism (c): goNamed(\'lit\') matches GoRoute(name: \'lit\') by exact '
    'string equality',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/go_named_caller.dart')
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/go_named_target.dart',
        ),
        hasLength(1),
      );
    },
  );

  // --- 0.5.0 goNamed duplicate `name:` gate -----------------

  test(
    'REFUSAL: a `name:` declared by two different GoRoutes never '
    'resolves via goNamed (no first-wins)',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/dup_named_caller.dart')
          .toList();
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates'),
        hasLength(1),
      );
      expect(
        callerEdges.where((e) => e['rel'] == 'navigates-to'),
        isEmpty,
      );
    },
  );

  test(
    'a unique goNamed `name:` still resolves (regression — the '
    'dedup gate must not break the ordinary single-declaration case)',
    () {
      engine.build(const []);
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>;
      final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();

      final callerEdges = edges
          .where((e) => e['src'] == 'file:lib/routing/go_named_caller.dart')
          .toList();
      expect(
        callerEdges.where(
          (e) =>
              e['rel'] == 'navigates-to' &&
              e['dst'] == 'file:lib/routing/go_named_target.dart',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'wiring (text) on the resolved caller inlines the resolved target; '
    'wiring on the unresolved caller shows (unresolved)',
    () {
      engine.build(const []);
      final resolved = Process.runSync(
        'dart',
        [cliSnapshot, 'wiring', 'details_caller.dart'],
      );
      expect(resolved.exitCode, 0, reason: resolved.stderr as String);
      expect(
        resolved.stdout as String,
        contains('→ lib/routing/details_page.dart'),
      );

      final unresolved = Process.runSync(
        'dart',
        [cliSnapshot, 'wiring', 'dynamic_caller.dart'],
      );
      expect(unresolved.exitCode, 0, reason: unresolved.stderr as String);
      expect(unresolved.stdout as String, contains('(unresolved)'));
    },
  );

  test(
    'navLines: a same-line collision (one resolvable nav, one unresolvable '
    'nav on the same physical line) renders each per its own unresolved '
    'flag, never borrowing the other call\'s target',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'wiring', 'collision_caller.dart'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(out, contains('(unresolved)'));
      expect(out, contains('→ lib/routing/details_page.dart'));
    },
  );

  test(
    'navLines: two resolvable navs sharing one physical line render '
    '"(resolved, ambiguous line)" instead of guessing either target',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'wiring', 'ambiguous_line_caller.dart'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final out = result.stdout as String;
      expect(out, contains('(resolved, ambiguous line)'));
      expect(out, isNot(contains('→ lib/routing/details_page.dart')));
      expect(out, isNot(contains('→ lib/routing/constant_page.dart')));
    },
  );

  test(
    'path <A> <B> traverses navigates-to edges between the caller and the '
    'page it navigates to',
    () {
      engine.build(const []);
      final result = Process.runSync(
        'dart',
        [cliSnapshot, 'path', 'details_caller.dart', 'details_page.dart'],
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout as String,
        contains('lib/routing/details_caller.dart'),
      );
      expect(
        result.stdout as String,
        contains('lib/routing/details_page.dart'),
      );
    },
  );

  test(
    'ambiguous file arg exits 2 with the candidate list on wiring, skeleton, '
    'and impact (shared resolver, 2.0 Batch C)',
    () {
      engine.build(const []);
      // Two fixture files share the basename dup_base.dart, so the
      // exact-suffix tiebreak matches BOTH and the arg stays ambiguous.
      for (final verb in ['wiring', 'skeleton', 'impact']) {
        final result = Process.runSync(
          'dart',
          [cliSnapshot, verb, 'dup_base.dart'],
        );
        final out = result.stdout as String;
        expect(result.exitCode, 2, reason: '$verb: $out${result.stderr}');
        expect(out, contains('"dup_base.dart" is ambiguous'), reason: verb);
        expect(out, contains('lib/ambig/a/dup_base.dart'), reason: verb);
        expect(out, contains('lib/ambig/b/dup_base.dart'), reason: verb);
      }
    },
  );

  test(
    'exact-suffix file arg resolves identically across wiring, skeleton, '
    'and impact (shared resolver, 2.0 Batch C)',
    () {
      engine.build(const []);
      // 'target.dart' is a substring of several files (fanin_target.dart,
      // material_page_target.dart, ...) but exactly one path ends with
      // '/target.dart' - the suffix tiebreak must pick lib/calls/target.dart
      // in every verb (wiring previously hard-failed on ANY 2+ matches).
      for (final verb in ['wiring', 'skeleton', 'impact']) {
        final result = Process.runSync(
          'dart',
          [cliSnapshot, verb, 'target.dart'],
        );
        final out = result.stdout as String;
        expect(result.exitCode, 0, reason: '$verb: $out${result.stderr}');
        // impact prints the seed's dependents, not the seed path itself -
        // caller_a.dart imports lib/calls/target.dart, so its presence proves
        // the seed resolved to the right file.
        expect(
          out,
          contains(
            verb == 'impact'
                ? 'lib/calls/caller_a.dart'
                : 'lib/calls/target.dart',
          ),
          reason: verb,
        );
        expect(out, isNot(contains('is ambiguous')), reason: verb);
      }
    },
  );

  test(
    'lint returns 64 on malformed codegraph.json without exiting the process '
    '(LintConfig.load throws, run() catches - 2.0 Batch C)',
    () {
      engine.build(const []);
      File('codegraph.json').writeAsStringSync('{not valid json');
      // In-process call: before this change LintConfig.load exit(64)ed the
      // whole process (this test could not even exist); now run() maps the
      // typed exception to the same exit code.
      expect(lint.run(const ['lint']), 64);
    },
  );

  test(
    'init --ci writes a workflow with the PR-comment step and fetch-depth',
    () {
      scaffold.init(
        const ['--ci'],
        version: '0.0.0-test',
        repoUrl: 'https://x',
      );
      final workflow =
          File('.github/workflows/code-graph.yml').readAsStringSync();
      expect(workflow, contains('Post codegraph diff card'));
      expect(workflow, contains('fetch-depth'));
    },
  );

  test(
    'init --ci workflow gains a lint step after the check step (0.7.0 Stage 3)',
    () {
      scaffold.init(
        const ['--ci'],
        version: '0.0.0-test',
        repoUrl: 'https://x',
      );
      final workflow =
          File('.github/workflows/code-graph.yml').readAsStringSync();
      expect(
          workflow, contains('dart pub global run codegraph:codegraph lint'));
      // Lint step comes after the check step, before the diff-comment step.
      final checkIdx = workflow.indexOf('codegraph:codegraph check');
      final lintIdx = workflow.indexOf('codegraph:codegraph lint');
      final diffIdx = workflow.indexOf('Post codegraph diff card');
      expect(checkIdx, greaterThan(0));
      expect(lintIdx, greaterThan(checkIdx));
      expect(diffIdx, greaterThan(lintIdx));
    },
  );

  test(
    'init --ci workflow carries the baseline-first comment above the lint step',
    () {
      scaffold.init(
        const ['--ci'],
        version: '0.0.0-test',
        repoUrl: 'https://x',
      );
      final workflow =
          File('.github/workflows/code-graph.yml').readAsStringSync();
      expect(workflow, contains('Fails on NEW architecture violations'));
      expect(workflow, contains("'codegraph lint --write-baseline'"));
      // Comment sits immediately above the lint step.
      final commentIdx =
          workflow.indexOf('# Fails on NEW architecture violations');
      final lintStepIdx = workflow.indexOf('name: Check architecture rules');
      expect(commentIdx, greaterThan(0));
      expect(lintStepIdx, greaterThan(commentIdx));
    },
  );

  test(
    'agent templates include docs-hygiene doctrine and stay product-agnostic',
    () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      final skill = File('.claude/skills/code-map/SKILL.md').readAsStringSync();
      final limits = File('docs/maps/LIMITATIONS.md').readAsStringSync();
      final claudeMd = File('CLAUDE.md').readAsStringSync();
      for (final text in [skill, claudeMd]) {
        expect(text, contains('Docs hygiene'),
            reason: 'skill and CLAUDE block must carry the hygiene rule');
        expect(text.toLowerCase(), isNot(contains('krdpass')));
        expect(text.toLowerCase(), isNot(contains('iproov')));
      }
      expect(limits, contains('Committed agent docs stay generic'));
      expect(limits.toLowerCase(), isNot(contains('krdpass')));
      expect(skill, contains('codegraph callers'));
      expect(skill, contains('codegraph callchain'));
    },
  );

  test(
    '_commandBlock (CLAUDE.md + skill) includes the lint command line '
    '(0.7.0 Stage 3)',
    () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      final claudeMd = File('CLAUDE.md').readAsStringSync();
      expect(claudeMd, contains('codegraph lint'));
      final skill = File('.claude/skills/code-map/SKILL.md').readAsStringSync();
      // The lint line lives in the shared command block appended to
      // CLAUDE.md/.mdc; the skill file has its own body — just confirm the
      // skill wasn't broken by the change.
      expect(skill, contains('codegraph brief'));
    },
  );

  test(
    'init prints a starter codegraph.json NOTE when lib/features/ exists '
    'and no config is present yet (0.7.0 Stage 3)',
    () {
      // The default fixture already has lib/features/{auth,vault}.
      final result = Process.runSync('dart', [cliSnapshot, 'init']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, contains('NOTE  no codegraph.json'));
      expect(
          result.stdout as String, contains('"features": ["lib/features/"]'));
      expect(
        result.stdout as String,
        contains('codegraph lint --write-baseline'),
      );
      // Guidance only — init must not write the file itself.
      expect(File('codegraph.json').existsSync(), isFalse);
    },
  );

  test(
    'init does NOT print the starter NOTE when codegraph.json already exists',
    () {
      File('codegraph.json').writeAsStringSync('{}');
      final result = Process.runSync('dart', [cliSnapshot, 'init']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, isNot(contains('no codegraph.json')));
    },
  );

  group('doctor', () {
    test('happy path: exit 0 and every check ok after init --ci + build', () {
      // Stamp at the binary version so the scaffolding-version check is `ok`.
      scaffold
          .init(const ['--ci'], version: binaryVersion, repoUrl: 'https://x');
      engine.build(const []);

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 0, reason: result.stdout as String);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      for (final c in checks) {
        expect(c['ok'], isTrue, reason: '${c['name']} should be ok: $c');
      }
    });

    test('missing hook file fails the "hook installed" check', () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      engine.build(const []);
      File('.claude/hooks/code-graph-refresh.sh').deleteSync();

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 1);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final hookCheck = checks.firstWhere((c) => c['name'] == 'hook installed');
      expect(hookCheck['ok'], isFalse);
      expect(hookCheck['fix'], contains('codegraph init'));
    });

    test(
      'hook wired under the WRONG event (PreToolUse, not SessionStart) '
      'fails the "hook installed" check, not a substring false-pass',
      () {
        scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
        engine.build(const []);
        File('.claude/settings.json').writeAsStringSync('''
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "bash .claude/hooks/code-graph-refresh.sh" }
        ]
      }
    ]
  }
}
''');

        final result =
            Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
        expect(result.exitCode, 1);
        final json =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        expect(json['ok'], isFalse);
        final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
        final hookCheck =
            checks.firstWhere((c) => c['name'] == 'hook installed');
        expect(hookCheck['ok'], isFalse);
      },
    );

    test(
      'git-tracked code_graph.json fails the "gitignore" check',
      () {
        scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
        engine.build(const []);
        Process.runSync('git', ['init', '-q']);
        Process.runSync('git', ['config', 'user.email', 'test@example.com']);
        Process.runSync('git', ['config', 'user.name', 'test']);
        // Force-add despite .gitignore to simulate a pre-gitignore tracked file.
        Process.runSync('git', ['add', '-f', 'docs/maps/code_graph.json']);

        final result =
            Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
        expect(result.exitCode, 1);
        final json =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        expect(json['ok'], isFalse);
        final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
        final gitignoreCheck =
            checks.firstWhere((c) => c['name'] == 'gitignore');
        expect(gitignoreCheck['ok'], isFalse);
        expect(gitignoreCheck['fix'], contains('git rm --cached'));
      },
    );

    test(
        'missing graph: "graph present" fails, other checks degrade gracefully',
        () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      // No engine.build() — graph never generated.

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 1);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final graphCheck = checks.firstWhere((c) => c['name'] == 'graph present');
      expect(graphCheck['ok'], isFalse);
      final formatCheck =
          checks.firstWhere((c) => c['name'] == 'binary vs graph format');
      expect(formatCheck['level'], 'note');
    });

    test('missing CI workflow is a note, not a failure, on its own', () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      engine.build(const []);
      // init() without --ci never writes the workflow file.
      expect(File('.github/workflows/code-graph.yml').existsSync(), isFalse);

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 0, reason: result.stdout as String);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final ciCheck = checks.firstWhere((c) => c['name'] == 'CI workflow');
      expect(ciCheck['ok'], isFalse);
      expect(ciCheck['level'], 'note');
      expect(json['ok'], isTrue);
    });

    test('doctor exit code is directly callable via doctor.run() too', () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      engine.build(const []);
      expect(doctor.run(const []), 0);
    });

    test('absent codegraph.json is a note, not a failure (0.7.0 Stage 3)', () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      engine.build(const []);
      expect(File('codegraph.json').existsSync(), isFalse);

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 0, reason: result.stdout as String);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final cfgCheck = checks.firstWhere((c) => c['name'] == 'codegraph.json');
      expect(cfgCheck['ok'], isTrue);
      expect(cfgCheck['level'], 'note');
    });

    test(
        'malformed codegraph.json notes the parse failure without failing the '
        'run (0.7.0 Stage 3)', () {
      scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
      engine.build(const []);
      File('codegraph.json').writeAsStringSync('{not valid json');

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 0, reason: result.stdout as String);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final cfgCheck = checks.firstWhere((c) => c['name'] == 'codegraph.json');
      expect(cfgCheck['ok'], isFalse);
      expect(cfgCheck['level'], 'note');
      expect(cfgCheck['detail'], contains('malformed'));
      expect(cfgCheck['fix'], contains('0.7.0-lint.md'));
    });

    test('scaffolding-version check notes a stale stamp with the upgrade fix',
        () {
      // Stamp at an old version; binary is newer → behind → note, not fail.
      scaffold.init(const [], version: '0.0.1', repoUrl: 'https://x');
      engine.build(const []);

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      expect(result.exitCode, 0, reason: result.stdout as String);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final c = checks.firstWhere((c) => c['name'] == 'scaffolding version');
      expect(c['ok'], isFalse);
      expect(c['level'], 'note');
      expect(c['detail'], contains('behind'));
      expect(c['fix'], 'codegraph upgrade');
    });

    test('scaffolding-version check is ok when stamp == binary', () {
      scaffold.init(const [], version: binaryVersion, repoUrl: 'https://x');
      engine.build(const []);

      final result = Process.runSync('dart', [cliSnapshot, 'doctor', '--json']);
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final checks = (json['checks'] as List).cast<Map<String, dynamic>>();
      final c = checks.firstWhere((c) => c['name'] == 'scaffolding version');
      expect(c['ok'], isTrue);
    });
  });

  group('scaffolding version stamp + upgrade (0.8.0 Stage A)', () {
    test('init stamps the version into every generated artifact', () {
      scaffold.init(const ['--ci', '--cursor'],
          version: '9.9.9', repoUrl: 'https://x');
      expect(File('CLAUDE.md').readAsStringSync(),
          contains('<!-- codegraph:begin v9.9.9 -->'));
      expect(File('.claude/hooks/code-graph-refresh.sh').readAsStringSync(),
          contains('codegraph-scaffold: v9.9.9'));
      expect(File('.claude/skills/code-map/SKILL.md').readAsStringSync(),
          contains('codegraph-scaffold: v9.9.9'));
      expect(File('.cursor/rules/codegraph.mdc').readAsStringSync(),
          contains('codegraph-scaffold: v9.9.9'));
      expect(File('.github/workflows/code-graph.yml').readAsStringSync(),
          contains('codegraph-scaffold: v9.9.9'));
    });

    test('scaffoldVersion() reads the CLAUDE marker, falls back to the hook',
        () {
      scaffold.init(const [], version: '1.2.3', repoUrl: 'https://x');
      expect(scaffold.scaffoldVersion(), '1.2.3');

      // Drop the CLAUDE block → falls back to the hook stamp.
      File('CLAUDE.md').writeAsStringSync('# no block here\n');
      expect(scaffold.scaffoldVersion(), '1.2.3');

      // No stamp anywhere → null (never-guess).
      File('.claude/hooks/code-graph-refresh.sh')
          .writeAsStringSync('#!/bin/bash\n');
      expect(scaffold.scaffoldVersion(), isNull);
    });

    test(
        'a CLAUDE.md that only DOCUMENTS the marker inside a fence is not '
        'treated as a real block (upgrade byte-identical, no false version, '
        'doctor not installed)', () {
      // No real block anywhere: CLAUDE.md merely mentions the marker inside a
      // fenced code block (indented, surrounded by prose on the line).
      final prose = '# My project\n\n'
          'We use codegraph. Its block looks like:\n\n'
          '```\n'
          '    <!-- codegraph:begin v9.9.9 -->\n'
          '    ...command list...\n'
          '    <!-- codegraph:end -->\n'
          '```\n\n'
          'End of prose.\n';
      File('CLAUDE.md').writeAsStringSync(prose);

      // scaffoldVersion() must NOT read v9.9.9 from mere prose.
      expect(scaffold.scaffoldVersion(), isNull);

      // upgrade must refuse to rewrite it and leave it byte-identical.
      final result = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      // (no hook/block installed → upgrade bails with the init hint, exit 66.)
      expect(result.exitCode, isNot(0));
      expect(File('CLAUDE.md').readAsStringSync(), prose);

      // doctor must NOT report the block as installed.
      final doc = Process.runSync('dart', [cliSnapshot, 'doctor']);
      expect(doc.stdout as String, contains('CLAUDE.md missing codegraph'));
    });

    test(
        'upgrade leaves documented-marker prose untouched but still upgrades '
        'a real on-its-own-line block in the same file', () {
      scaffold.init(const [], version: '0.0.1', repoUrl: 'https://x');
      // Append prose that documents the marker inside a fence AFTER the real
      // block. The real block (its markers alone on their lines) must upgrade;
      // the fenced mention must survive byte-for-byte.
      final claude = File('CLAUDE.md');
      const fenced = '\n## How the block looks\n\n'
          '```\n'
          'here is `<!-- codegraph:begin v9.9.9 -->` inline\n'
          '```\n';
      claude.writeAsStringSync('${claude.readAsStringSync()}$fenced');

      final result = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final after = claude.readAsStringSync();
      // Real block upgraded to the binary version.
      expect(after, contains('<!-- codegraph:begin v$binaryVersion -->'));
      expect(after, isNot(contains('codegraph:begin v0.0.1')));
      // The fenced documentation mention is preserved verbatim.
      expect(after, endsWith(fenced));
      expect(after, contains('`<!-- codegraph:begin v9.9.9 -->` inline'));
    });

    test(
        'upgrade refreshes a stale skill + CLAUDE block, preserves surrounding '
        'user content, never touches settings/LIMITATIONS, is idempotent, and '
        'does not create absent cursor/workflow files', () {
      // Install at an old version WITHOUT --ci/--cursor (no workflow/mdc).
      scaffold.init(const [], version: '0.0.1', repoUrl: 'https://x');

      // Wrap the CLAUDE block with user prose on both sides.
      final claude = File('CLAUDE.md');
      final wrapped = 'MY HEADER PROSE\n\n'
          '${claude.readAsStringSync()}\nMY FOOTER PROSE\n';
      claude.writeAsStringSync(wrapped);

      // Snapshot the host-owned files upgrade must never touch.
      final settingsBefore = File('.claude/settings.json').readAsStringSync();
      final limitsBefore = File('docs/maps/LIMITATIONS.md').readAsStringSync();

      final result = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      expect(result.exitCode, 0, reason: result.stderr as String);

      // Skill + CLAUDE block now carry the binary version.
      expect(File('.claude/skills/code-map/SKILL.md').readAsStringSync(),
          contains('codegraph-scaffold: v$binaryVersion'));
      final after = claude.readAsStringSync();
      expect(after, contains('<!-- codegraph:begin v$binaryVersion -->'));
      // Surrounding user prose preserved byte-for-byte.
      expect(after, startsWith('MY HEADER PROSE\n\n'));
      expect(after, endsWith('MY FOOTER PROSE\n'));
      expect(after, isNot(contains('v0.0.1')));

      // Host-owned files untouched.
      expect(File('.claude/settings.json').readAsStringSync(), settingsBefore);
      expect(File('docs/maps/LIMITATIONS.md').readAsStringSync(), limitsBefore);

      // Opt-in files that weren't present are NOT created by upgrade.
      expect(File('.cursor/rules/codegraph.mdc').existsSync(), isFalse);
      expect(File('.github/workflows/code-graph.yml').existsSync(), isFalse);

      // Idempotent: a second upgrade changes nothing and reports unchanged.
      final claudeAfterFirst = claude.readAsStringSync();
      final skillAfterFirst =
          File('.claude/skills/code-map/SKILL.md').readAsStringSync();
      final second = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      expect(second.exitCode, 0);
      expect(second.stdout as String, contains('unchanged'));
      expect(claude.readAsStringSync(), claudeAfterFirst);
      expect(File('.claude/skills/code-map/SKILL.md').readAsStringSync(),
          skillAfterFirst);
    });

    test('upgrade refreshes cursor + workflow only when they already exist',
        () {
      scaffold.init(const ['--ci', '--cursor'],
          version: '0.0.1', repoUrl: 'https://x');
      final result = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      expect(result.exitCode, 0);
      expect(File('.cursor/rules/codegraph.mdc').readAsStringSync(),
          contains('codegraph-scaffold: v$binaryVersion'));
      expect(File('.github/workflows/code-graph.yml').readAsStringSync(),
          contains('codegraph-scaffold: v$binaryVersion'));
    });

    test('upgrade with no scaffolding at all tells the user to init, exit != 0',
        () {
      // Fresh package root, nothing installed.
      final result = Process.runSync('dart', [cliSnapshot, 'upgrade']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr as String, contains('codegraph init'));
    });

    test('passport prepends the skew nudge on a stale stamp, omits it current',
        () {
      scaffold.init(const [], version: '0.0.1', repoUrl: 'https://x');
      engine.build(const []);

      final stale = Process.runSync('dart', [cliSnapshot, 'passport']);
      expect(stale.exitCode, 0);
      expect(
          stale.stdout as String,
          contains("codegraph: skills are v0.0.1 (binary v$binaryVersion) — "
              "run 'codegraph upgrade' to refresh"));

      // Re-stamp to current → nudge gone.
      Process.runSync('dart', [cliSnapshot, 'upgrade']);
      final current = Process.runSync('dart', [cliSnapshot, 'passport']);
      expect(current.stdout as String,
          isNot(contains('run \'codegraph upgrade\'')));
    });

    test('passport omits the nudge entirely when no scaffolding is present',
        () {
      // Build a graph but never init → no scaffolding files.
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'passport']);
      expect(result.exitCode, 0);
      expect(result.stdout as String, isNot(contains('codegraph upgrade')));
    });

    test('passport prints the skew nudge even with NO graph present (exit 66)',
        () {
      // Install stale scaffolding but do NOT build. --no-rebuild keeps the
      // no-graph state reachable (default behavior now auto-builds it).
      scaffold.init(const [], version: '0.0.1', repoUrl: 'https://x');
      final result =
          Process.runSync('dart', [cliSnapshot, 'passport', '--no-rebuild']);
      expect(result.exitCode, 66);
      expect(
          result.stdout as String,
          contains("codegraph: skills are v0.0.1 (binary v$binaryVersion) — "
              "run 'codegraph upgrade' to refresh"));
    });

    test('skewOf: behind, current, ahead, and unknown (never-guess)', () {
      expect(skewOf('0.7.0', '0.8.0'), ScaffoldSkew.behind);
      expect(skewOf('v0.7.0', '0.7.0'), ScaffoldSkew.current);
      expect(skewOf('0.9.0', '0.8.0'), ScaffoldSkew.current); // ahead → no nag
      expect(skewOf(null, '0.8.0'), ScaffoldSkew.unknown);
      expect(skewOf('garbage', '0.8.0'), ScaffoldSkew.unknown);
      expect(skewOf('1.2', '0.8.0'), ScaffoldSkew.unknown); // too few parts
      // Patch-tolerant: a pure-fix patch does not re-nag; a minor bump does.
      expect(skewOf('0.9.0', '0.9.7'), ScaffoldSkew.current); // patch → no nag
      expect(skewOf('0.9.0', '0.10.0'), ScaffoldSkew.behind); // minor → nag
      expect(skewOf('0.9.0', '1.0.0'), ScaffoldSkew.behind); // major → nag
    });
  });

  group('package resolution — path deps beat stray backup copies', () {
    test(
      'a packages/<name>_backup_<ts> copy that duplicates a real package name '
      'is excluded; imports resolve to the real path-dep, not the backup',
      () {
        final saved = Directory.current;
        final proj = Directory.systemTemp.createTempSync('codegraph_pkgres_');
        try {
          File('${proj.path}/pubspec.yaml').writeAsStringSync(
            'name: host\n'
            'environment:\n  sdk: ^3.5.0\n'
            'dependencies:\n  real_pkg:\n    path: packages/real_pkg\n',
          );
          File('${proj.path}/lib/app.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              "import 'package:real_pkg/widget.dart';\n"
              'class App { void build() => RealWidget(); }\n',
            );
          // Real declared dependency.
          File('${proj.path}/packages/real_pkg/pubspec.yaml')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
                'name: real_pkg\nenvironment:\n  sdk: ^3.5.0\n');
          File('${proj.path}/packages/real_pkg/lib/widget.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('class RealWidget {}\n');
          // Stray backup copy: SAME package name (`real_pkg`), NOT a declared
          // dependency — the `foo_api_backup_<ts>` case. Before the
          // path-dep fix it sorted last and overwrote the real package.
          File('${proj.path}/packages/real_pkg_backup_1783/pubspec.yaml')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
                'name: real_pkg\nenvironment:\n  sdk: ^3.5.0\n');
          File('${proj.path}/packages/real_pkg_backup_1783/lib/widget.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('class RealWidget {}\n');

          Directory.current = proj.path;
          engine.build(const []);
          final graph = Graph.load()!;
          final ids = graph.nodes.map((n) => n.id).toList();

          expect(
            ids.where((id) => id.contains('real_pkg_backup')),
            isEmpty,
            reason: 'the stray backup copy must not enter the graph',
          );
          expect(ids, contains('file:packages/real_pkg/lib/widget.dart'));
          expect(
            graph.edges.any((e) =>
                e.rel == 'imports' &&
                e.src == 'file:lib/app.dart' &&
                e.dst == 'file:packages/real_pkg/lib/widget.dart'),
            isTrue,
            reason:
                'the import must resolve to the real package, not the backup',
          );
        } finally {
          Directory.current = saved;
          proj.deleteSync(recursive: true);
        }
      },
    );
  });

  group('impls includes test/integration fakes', () {
    test(
      'impls lists a fake implementing a lib interface only in a test root, '
      'labeled and kept separate from resolved lib subtypes',
      () {
        final saved = Directory.current;
        final proj = Directory.systemTemp.createTempSync('codegraph_timpls_');
        try {
          File('${proj.path}/pubspec.yaml')
              .writeAsStringSync('name: host\nenvironment:\n  sdk: ^3.5.0\n');
          File('${proj.path}/lib/repo.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              'abstract class Repo {}\n'
              'class HttpRepo implements Repo {}\n',
            );
          // A fake that implements the interface ONLY in a test root — the
          // lib-only graph never sees it. impls must still surface it.
          File('${proj.path}/test/fake_repo_test.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              "import 'package:host/repo.dart';\n"
              'class FakeRepo implements Repo {}\n',
            );
          Directory.current = proj.path;
          engine.build(const []);

          final res = Process.runSync('dart', [cliSnapshot, 'impls', 'Repo']);
          expect(res.exitCode, 0, reason: res.stderr as String);
          final out = res.stdout as String;
          // Resolved lib subtype still shown.
          expect(out, contains('HttpRepo -> Repo'));
          // Test fake surfaced, in its own labeled section, with file:line.
          expect(out, contains('test fakes'));
          expect(out, contains('FakeRepo implements Repo'));
          expect(out, contains('test/fake_repo_test.dart'));

          final jsonRes =
              Process.runSync('dart', [cliSnapshot, 'impls', 'Repo', '--json']);
          final decoded = jsonDecode(jsonRes.stdout as String) as Map;
          final testSubs = (decoded['testSubtypes'] as List).cast<Map>();
          expect(
            testSubs.any((t) => t['subtype'] == 'FakeRepo'),
            isTrue,
            reason: 'test fake must appear under testSubtypes in --json',
          );
          // Resolved lib results stay clean (no test fakes leaking in).
          final results = (decoded['results'] as List).cast<Map>();
          expect(results.any((r) => r['subtype'] == 'FakeRepo'), isFalse);
        } finally {
          Directory.current = saved;
          proj.deleteSync(recursive: true);
        }
      },
    );
  });

  group('monorepo hook self-location', () {
    test(
      'init from a package root that is not the git root prints monorepo '
      'guidance',
      () {
        final pkgDir = Directory('pkg')..createSync();
        File('${pkgDir.path}/pubspec.yaml')
            .writeAsStringSync('name: pkg\nenvironment:\n  sdk: ^3.5.0\n');
        Process.runSync('git', ['init', '-q']);
        Directory.current = pkgDir.path;
        final result = Process.runSync(
          'dart',
          [cliSnapshot, 'init'],
        );
        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(
          result.stdout as String,
          contains('is not the git root'),
        );
      },
    );

    test(
      'hook self-locates a one-level-down package (pubspec.yaml + '
      'docs/maps/) when CLAUDE_PROJECT_DIR is the git root, and cd\'s into '
      'it before emitting passport output',
      () {
        // tempDir is the git root here; the "package" lives in tempDir/pkg.
        final pkgDir = Directory('${tempDir.path}/pkg')..createSync();
        File('${pkgDir.path}/pubspec.yaml')
            .writeAsStringSync('name: pkg\nenvironment:\n  sdk: ^3.5.0\n');
        File('${pkgDir.path}/lib/pkg.dart')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('class Pkg {}\n');
        Directory.current = pkgDir.path;
        scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
        engine.build(const []);

        final hookPath = '${pkgDir.path}/.claude/hooks/code-graph-refresh.sh';
        final result = Process.runSync(
          'bash',
          [hookPath],
          environment: {
            'CLAUDE_PROJECT_DIR': tempDir.path,
            'PATH': Platform.environment['PATH'] ?? '',
          },
        );
        expect(result.exitCode, 0, reason: result.stderr as String);
        // Fail-safe self-location succeeded: no error about a missing
        // pubspec/docs-maps, and it reached the codegraph-not-installed or
        // passport branch instead of bailing out on `cd` at the git root.
        expect(
          result.stdout as String,
          isNot(contains('run from the package root')),
        );
      },
    );

    test(
      'hook exits 0 silently when CLAUDE_PROJECT_DIR has no pubspec.yaml '
      'and no matching one-level-down subdir',
      () {
        scaffold.init(const [], version: '0.0.0-test', repoUrl: 'https://x');
        engine.build(const []);
        final hookPath = '${tempDir.path}/.claude/hooks/code-graph-refresh.sh';

        final emptyRoot = Directory('${tempDir.path}/empty_root')..createSync();
        final result = Process.runSync(
          'bash',
          [hookPath],
          environment: {
            'CLAUDE_PROJECT_DIR': emptyRoot.path,
            'PATH': Platform.environment['PATH'] ?? '',
          },
        );
        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout as String, isEmpty);
      },
    );
  });

  group('lint (0.7.0 Stage 1)', () {
    test('cross-feature-import fires on a cross-unit import, not same-unit',
        () {
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 1);
      final out = result.stdout as String;
      // auth_page imports vault_page (different units) -> fires.
      expect(
          out,
          contains(
              'lib/features/auth/auth_page.dart -> lib/features/vault/vault_page.dart'));
      // auth_page imports auth_helper (SAME unit) -> must NOT appear as a
      // cross-feature violation.
      expect(
          out,
          isNot(contains(
              'auth_page.dart -> lib/features/auth/auth_helper.dart')));
    });

    test('crossFeatureAllow suppresses the allowed pair', () {
      engine.build(const []);
      File('codegraph.json')
          .writeAsStringSync('{"crossFeatureAllow": ["auth -> vault"]}');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      final out = result.stdout as String;
      expect(out, isNot(contains('cross-feature-import')));
      // layer-order still fires, so exit is still 1.
      expect(result.exitCode, 1);
    });

    test(
        'layer-order fires repository->view with the import line, not view->repository',
        () {
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      final out = result.stdout as String;
      // thing_repository imports thing_page on line 1 -> forbidden direction.
      expect(
          out,
          contains(
              'lib/lintlayer/thing_repository.dart -> lib/lintlayer/thing_page.dart '
              '(lib/lintlayer/thing_repository.dart:1)'));
      // other_page (view) imports other_repository -> allowed direction, no fire.
      expect(
          out,
          isNot(contains(
              'other_page.dart -> lib/lintlayer/other_repository.dart')));
    });

    test('lint exits 0 on a clean graph (no features/layers to violate)', () {
      // Fresh, empty-of-violations project: one lib file, no imports.
      final clean =
          Directory.systemTemp.createTempSync('codegraph_lint_clean_');
      File('${clean.path}/pubspec.yaml')
          .writeAsStringSync('name: clean\nenvironment:\n  sdk: ^3.5.0\n');
      File('${clean.path}/lib/only.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('class Only {}\n');
      final saved = Directory.current;
      Directory.current = clean;
      try {
        engine.build(const []);
        final result = Process.runSync('dart', [cliSnapshot, 'lint']);
        expect(result.exitCode, 0);
        expect(result.stdout as String, contains('clean'));
      } finally {
        Directory.current = saved;
        clean.deleteSync(recursive: true);
      }
    });

    test('lint returns 66 with no graph', () {
      final empty = Directory.systemTemp.createTempSync('codegraph_lint_none_');
      final result = Process.runSync('dart', [cliSnapshot, 'lint'],
          workingDirectory: empty.path);
      expect(result.exitCode, 66);
      empty.deleteSync(recursive: true);
    });

    test('output ordering is deterministic (run twice -> identical)', () {
      engine.build(const []);
      final a = Process.runSync('dart', [cliSnapshot, 'lint']);
      final b = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(a.stdout, b.stdout);
      expect(a.exitCode, b.exitCode);
    });

    test('LintConfig: absent file -> defaults', () {
      final c = lint.LintConfig.load('does_not_exist.json');
      expect(c.features, ['lib/features/']);
      expect(c.crossFeatureAllow, isEmpty);
      expect(c.layersForbid, contains('repository -> view'));
    });

    test('LintConfig: unknown key warns on stderr but still runs', () {
      engine.build(const []);
      File('codegraph.json').writeAsStringSync('{"bogusKey": 1}');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.stderr as String,
          contains('unknown codegraph.json key(s): bogusKey'));
      // Defaults still apply -> the cross-feature violation still fires.
      expect(result.exitCode, 1);
    });

    test('--json envelope: violations, counts, ok', () {
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint', '--json']);
      expect(result.exitCode, 1);
      final j = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(j['verb'], 'lint');
      expect(j['ok'], isFalse);
      final counts = j['counts'] as Map<String, dynamic>;
      expect(counts['cross-feature-import'], greaterThanOrEqualTo(1));
      expect(counts['layer-order'], greaterThanOrEqualTo(1));
    });
  });

  group('lint rules 3-4 (0.7.0 Stage 2 — Part A)', () {
    test('banned-provider-kind fires when the kind is configured, else silent',
        () {
      engine.build(const []);

      // Not configured by default → no banned-provider-kind violations.
      final off = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(off.stdout as String, isNot(contains('banned-provider-kind')));

      // Configure StateProvider as banned → the StateProvider decl fires,
      // pointing at its declaring file and line.
      File('codegraph.json')
          .writeAsStringSync('{"banned_provider_kinds": ["StateProvider"]}');
      final on = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(on.exitCode, 1);
      final out = on.stdout as String;
      expect(out, contains('banned-provider-kind'));
      expect(
          out,
          contains('lib/lintprov/banned_provider.dart -> '
              'lintBannedProvider: StateProvider'));
    });

    test('provider-placement fires for a non-home role, not for an allowed one',
        () {
      engine.build(const []);
      // provider = allowed home, view = not. The StateProvider lives in a
      // *_provider.dart (role provider → allowed → no fire); the plain
      // Provider lives in a *_page.dart (role view → not allowed → fires).
      File('codegraph.json')
          .writeAsStringSync('{"provider_homes": ["provider", "controller"]}');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 1);
      final out = result.stdout as String;
      expect(out, contains('provider-placement'));
      // Misplaced provider (view role) fires.
      expect(
          out,
          contains(
              'lib/lintprov/misplaced_page.dart -> lintMisplacedProvider (view)'));
      // The provider-role declaration is an allowed home → must NOT appear.
      expect(
          out, isNot(contains('banned_provider.dart -> lintBannedProvider')));
    });

    test('provider-placement entirely silent when provider_homes is absent',
        () {
      engine.build(const []);
      // No provider_homes key → rule OFF (never-guess). Default config has no
      // banned kinds either, so no provider rules can fire at all.
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.stdout as String, isNot(contains('provider-placement')));
    });
  });

  group('lint baseline ratchet (0.7.0 Stage 2 — Part B)', () {
    const baselinePath = 'docs/maps/lint-baseline.json';

    test('write-baseline then plain lint → all baselined, exit 0', () {
      engine.build(const []);
      final wrote =
          Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);
      expect(wrote.exitCode, 0);
      expect(wrote.stdout as String, contains('wrote baseline'));
      expect(File(baselinePath).existsSync(), isTrue);

      final plain = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(plain.exitCode, 0);
      final out = plain.stdout as String;
      expect(out, contains('baselined'));
      // No NEW violation sections in the output.
      expect(out, isNot(contains('cross-feature-import (')));
      expect(out, isNot(contains('layer-order (')));
    });

    test('a NEW violation after baselining fires; baselined ones stay silent',
        () {
      engine.build(const []);
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);

      // Introduce a brand-new cross-feature import (settings → auth), rebuild,
      // then lint. Only the new crossing is NEW; the pre-existing ones remain
      // baselined and silent.
      File('lib/features/settings/settings_page.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:fixture/features/auth/auth_helper.dart';

class SettingsPage {
  void build() => authHelper();
}
''');
      // Keep it reachable so it isn't dropped as an orphan.
      File('lib/lintbarrel/lint_routes.dart').writeAsStringSync('''
export 'package:fixture/features/auth/auth_page.dart';
export 'package:fixture/lintlayer/thing_repository.dart';
export 'package:fixture/lintlayer/other_page.dart';
export 'package:fixture/features/settings/settings_page.dart';
''');
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 1);
      final out = result.stdout as String;
      // The new crossing is reported.
      expect(
          out,
          contains(
              'lib/features/settings/settings_page.dart -> lib/features/auth/auth_helper.dart'));
      // A baselined crossing (auth → vault) is NOT reported.
      expect(
          out,
          isNot(contains(
              'lib/features/auth/auth_page.dart -> lib/features/vault/vault_page.dart')));
    });

    test('identity excludes line: moving a violating import stays baselined',
        () {
      engine.build(const []);
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);

      // Move thing_repository's forbidden import (repository -> view) to a
      // different line by prepending a blank/comment line. Same rule|from|to,
      // different line → identity unchanged → still baselined.
      File('lib/lintlayer/thing_repository.dart').writeAsStringSync('''
// a leading comment shifts the import to a later line
import 'package:fixture/lintlayer/thing_page.dart';

class ThingRepository {
  void build() => ThingPage();
}
''');
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 0);
      expect(
          result.stdout as String,
          isNot(contains(
              'lib/lintlayer/thing_repository.dart -> lib/lintlayer/thing_page.dart')));
    });

    test('--write-baseline is byte-deterministic (write twice → identical)',
        () {
      engine.build(const []);
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);
      final first = File(baselinePath).readAsBytesSync();
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);
      final second = File(baselinePath).readAsBytesSync();
      expect(second, first);
    });

    test('a removed violation becomes a stale baseline entry (exit still 0)',
        () {
      engine.build(const []);
      Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);

      // Remove the forbidden import from thing_repository → its layer-order
      // violation disappears, leaving a stale baseline entry. Exit stays 0
      // (fixed violations are good news), but a note reports the staleness.
      File('lib/lintlayer/thing_repository.dart').writeAsStringSync('''
class ThingRepository {}
''');
      engine.build(const []);
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('stale baseline entries'));
    });

    test('no baseline present → Stage 1 behavior (all violations new, exit 1)',
        () {
      engine.build(const []);
      // Fresh build writes no baseline; ensure none exists.
      final bf = File(baselinePath);
      if (bf.existsSync()) bf.deleteSync();
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 1);
      final out = result.stdout as String;
      expect(out, contains('cross-feature-import'));
      expect(out, isNot(contains('baselined')));
    });

    test('a malformed baseline is fatal (exit 64 + message), not a stack trace',
        () {
      engine.build(const []);
      File(baselinePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('not json{{');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      // 64, not 255 (uncaught FormatException) and not 1 (treated as empty).
      expect(result.exitCode, 64);
      expect(result.stderr as String, contains('is not valid JSON'));
    });

    test('a baseline of the wrong shape is fatal (exit 64), not empty', () {
      engine.build(const []);
      // Valid JSON but missing the {version, violations} shape.
      File(baselinePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"nope": true}');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      expect(result.exitCode, 64);
      expect(result.stderr as String, contains('malformed'));
    });
  });

  group('lint config normalization (0.7.0 Lint fixes)', () {
    test('features prefix without trailing slash is normalized to end with /',
        () {
      final c = lint.LintConfig.fromJson({
        'features': ['lib/features']
      });
      expect(c.features, ['lib/features/']);
    });

    test('an already-slashed features prefix is left unchanged', () {
      final c = lint.LintConfig.fromJson({
        'features': ['lib/features/']
      });
      expect(c.features, ['lib/features/']);
    });

    test('crossFeatureAllow pairs are canonicalized (spacing variants)', () {
      final c = lint.LintConfig.fromJson({
        'crossFeatureAllow': ['auth->vault', 'a  ->  b', 'no-arrow', 'x -> y']
      });
      // Canonical single-spaced; entries without -> dropped.
      expect(c.crossFeatureAllow, ['auth -> vault', 'a -> b', 'x -> y']);
    });

    test(
        'features:["lib/features"] (no slash) is boundary-safe: cross-unit '
        'fires but a sibling features_experimental/ dir does NOT', () {
      final proj =
          Directory.systemTemp.createTempSync('codegraph_lint_boundary_');
      final saved = Directory.current;
      try {
        File('${proj.path}/pubspec.yaml')
            .writeAsStringSync('name: bnd\nenvironment:\n  sdk: ^3.5.0\n');
        // Real cross-unit import inside lib/features/ → MUST fire.
        File('${proj.path}/lib/features/a/a_page.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:bnd/features/b/b_page.dart';

class APage {
  void build() => BPage();
}
''');
        File('${proj.path}/lib/features/b/b_page.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('class BPage {}\n');
        // A sibling dir sharing the "lib/features" prefix — must NOT be
        // straddled once the prefix is normalized to "lib/features/".
        File('${proj.path}/lib/features_experimental/c/c_page.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:bnd/features_experimental/d/d_page.dart';

class CPage {
  void build() => DPage();
}
''');
        File('${proj.path}/lib/features_experimental/d/d_page.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('class DPage {}\n');
        File('${proj.path}/codegraph.json')
            .writeAsStringSync('{"features": ["lib/features"]}');

        Directory.current = proj;
        engine.build(const []);
        final result = Process.runSync('dart', [cliSnapshot, 'lint']);
        expect(result.exitCode, 1);
        final out = result.stdout as String;
        // The genuine cross-unit import fires.
        expect(
            out,
            contains('lib/features/a/a_page.dart -> '
                'lib/features/b/b_page.dart'));
        // The sibling-dir crossing does NOT (boundary respected).
        expect(out, isNot(contains('features_experimental')));
      } finally {
        Directory.current = saved;
        proj.deleteSync(recursive: true);
      }
    });

    test('crossFeatureAllow:"auth->vault" (no spaces) suppresses the crossing',
        () {
      engine.build(const []);
      File('codegraph.json')
          .writeAsStringSync('{"crossFeatureAllow": ["auth->vault"]}');
      final result = Process.runSync('dart', [cliSnapshot, 'lint']);
      final out = result.stdout as String;
      // Same suppression as the canonical "auth -> vault" form.
      expect(out, isNot(contains('cross-feature-import')));
    });

    test(
        'two banned providers of the same kind in ONE file are distinct '
        'baseline identities (do not collapse)', () {
      final proj =
          Directory.systemTemp.createTempSync('codegraph_lint_collapse_');
      final saved = Directory.current;
      try {
        File('${proj.path}/pubspec.yaml')
            .writeAsStringSync('name: col\nenvironment:\n  sdk: ^3.5.0\n');
        File('${proj.path}/lib/two_providers.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
final aProvider = StateProvider<int>((ref) => 1);
final bProvider = StateProvider<int>((ref) => 2);
''');
        File('${proj.path}/codegraph.json')
            .writeAsStringSync('{"banned_provider_kinds": ["StateProvider"]}');

        Directory.current = proj;
        engine.build(const []);
        final wrote =
            Process.runSync('dart', [cliSnapshot, 'lint', '--write-baseline']);
        expect(wrote.exitCode, 0);
        // Two distinct identities → (2), not (1) (name-qualified identity).
        expect(wrote.stdout as String, contains('wrote baseline (2)'));
      } finally {
        Directory.current = saved;
        proj.deleteSync(recursive: true);
      }
    });
  });

  group('blueprint (0.8.0 Stage B)', () {
    test('LAYERED feature: layers appear in build order', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      expect(r.exitCode, 0);
      final out = r.stdout as String;
      // Header.
      expect(out, contains('blueprint: lib/features/sample'));
      // The intent reframes blueprint as a MAP that prompts deeper work, not a
      // finished plan — it must push the agent toward study + judgment.
      expect(out, contains('STUDY THESE'));
      expect(out, contains('DECISIONS THE GRAPH CAN\'T MAKE'));
      expect(out, contains('RUNTIME BEHAVIOR'));
      // Layer labels in domain → data → application → presentation → routing
      // order.
      int idx(String s) => out.indexOf(s);
      expect(idx('domain/'), greaterThanOrEqualTo(0));
      expect(idx('domain/'), lessThan(idx('data/')));
      expect(idx('data/'), lessThan(idx('application/')));
      expect(idx('application/'), lessThan(idx('presentation/')));
      expect(idx('presentation/'), lessThan(idx('routing/')));
      // A file with its role + symbol.
      expect(out, contains('sample_repository.dart [repository]'));
      expect(out, contains('SampleRepository'));
    });

    test('internal-vs-external wiring split + external seam', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final out = r.stdout as String;
      // The controller watches an in-feature provider (internal) AND a
      // cross-area provider (external, declared in lib/sampleext).
      final wiring = out.substring(out.indexOf('sampleControllerProvider'));
      expect(wiring, contains('internal: sampleRepositoryProvider'));
      expect(wiring, contains('external: sampleExtProvider'));
      // External seam lists the outside provider with its declaring file.
      final seam = out.substring(out.indexOf('EXTERNAL SEAM'));
      expect(
          seam,
          contains(
              'sampleExtProvider ← lib/sampleext/sample_ext_provider.dart'));
    });

    test(
        'field-held _ref read is detected (receiver broadening) and a '
        'non-provider file\'s cross-area read surfaces in the external seam',
        () {
      engine.build(const []);
      // The graph must carry the page's `_ref.read(sampleExtPageProvider)` as a
      // read edge — a field-held Ref, not a local `ref` (regression guard for
      // the receiver broadening found by the A/B eval).
      final graph =
          jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map;
      final edges = (graph['edges'] as List).cast<Map>();
      expect(
        edges.any((e) =>
            e['src'] ==
                'file:lib/features/sample/presentation/sample_page.dart' &&
            e['rel'] == 'reads' &&
            (e['dst'] as String).contains('sampleExtPageProvider')),
        isTrue,
        reason: '_ref.read(sampleExtPageProvider) must be a read edge',
      );
      // And blueprint's EXTERNAL SEAM must include it, even though ONLY the page
      // (a non-provider file) reads it — the provider-only seam would miss it.
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final seam = (r.stdout as String);
      expect(
          seam.substring(seam.indexOf('EXTERNAL SEAM')),
          contains(
              'sampleExtPageProvider ← lib/sampleext/sample_ext_provider.dart'));
    });

    test('multi-provider file: file-level deps, no per-provider fabrication',
        () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final out = r.stdout as String;
      // sample_repository_provider.dart declares TWO providers; only the
      // repository provider watches sampleExtProvider. The output must NOT
      // assert an external dep under the non-watching cookie-jar sibling.
      expect(
          out,
          contains('sample_repository_provider.dart declares 2 '
              'providers:'));
      expect(out, contains('file-level deps'));
      // No precise per-provider external line for the cookie-jar provider.
      // (There is no "sampleCookieJarProvider (Provider)\n  → external:" block.)
      final cookieIdx = out.indexOf('sampleCookieJarProvider (Provider)');
      // The provider name appears only in the grouped listing, never as its own
      // per-provider header followed by a → external line.
      expect(
        RegExp(r'sampleCookieJarProvider \(Provider\)\s*\n\s*→').hasMatch(out),
        isFalse,
      );
      expect(cookieIdx, greaterThanOrEqualTo(0)); // still listed in the group
    });

    test('multi-provider file: --json carries fileGranular + providers', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample', '--json']);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final providers = (j['providers'] as List).cast<Map<String, dynamic>>();
      // The two-provider file is a single fileGranular record listing both
      // providers, with file-level deps (not attributed per provider).
      final grouped = providers.firstWhere((p) =>
          p['fileGranular'] == true &&
          (p['providers'] as List).contains('sampleCookieJarProvider'));
      expect((grouped['providers'] as List),
          containsAll(['sampleCookieJarProvider', 'sampleRepositoryProvider']));
      expect(
          (grouped['external'] as List),
          contains(
              'sampleExtProvider ← lib/sampleext/sample_ext_provider.dart'));
      // No single-provider record names the cookie-jar provider (it shares a
      // file — never per-provider attributed).
      expect(
        providers.any((p) =>
            p['fileGranular'] == false &&
            p['name'] == 'sampleCookieJarProvider'),
        isFalse,
      );
      // The single-provider controller stays precise (fileGranular:false).
      final ctrl =
          providers.firstWhere((p) => p['name'] == 'sampleControllerProvider');
      expect(ctrl['fileGranular'], false);
      expect((ctrl['internal'] as List), contains('sampleRepositoryProvider'));
    });

    test('routes reported + naming suffixes detected', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final out = r.stdout as String;
      // A route (either the navigates target or the routing file) is reported.
      final routes = out.substring(out.indexOf('ROUTES REGISTERED'));
      expect(routes, contains('sample_routes.dart [routing]'));
      // A naming suffix that actually occurs.
      expect(out, contains('*_repository.dart'));
      expect(out, contains('*_controller.dart'));
      expect(out, contains('*Provider'));
    });

    test('test-presence line reflects testRefs', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final out = r.stdout as String;
      // sample_controller.dart is referenced by sample_controller_test.dart.
      final tests = RegExp(r'TESTS: (\d+)/(\d+) files').firstMatch(out)!;
      expect(int.parse(tests.group(1)!), greaterThanOrEqualTo(1));
      // An untested file is listed (e.g. the widget).
      expect(out, contains('sample_button.dart'));
    });

    test('FLAT feature falls back to role grouping', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/flat']);
      expect(r.exitCode, 0);
      final out = r.stdout as String;
      // Role labels (not layer dirs), in repository → controller → view order.
      int idx(String s) => out.indexOf(s);
      expect(idx('repository/'), greaterThanOrEqualTo(0));
      expect(idx('controller/'), greaterThanOrEqualTo(0));
      expect(idx('view/'), greaterThanOrEqualTo(0));
      expect(idx('repository/'), lessThan(idx('controller/')));
      expect(idx('controller/'), lessThan(idx('view/')));
    });

    test('deterministic: identical graph → identical output', () {
      engine.build(const []);
      final a = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      final b = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample']);
      expect(a.stdout, b.stdout);
    });

    test('--json emits structured sections', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/sample', '--json']);
      expect(r.exitCode, 0);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      expect(j['verb'], 'blueprint');
      expect(j['feature'], 'lib/features/sample');
      expect((j['layers'] as List).first['label'], 'domain');
      final providers = (j['providers'] as List).cast<Map<String, dynamic>>();
      final ctrl =
          providers.firstWhere((p) => p['name'] == 'sampleControllerProvider');
      expect((ctrl['internal'] as List), contains('sampleRepositoryProvider'));
      expect(
          (ctrl['external'] as List),
          contains(
              'sampleExtProvider ← lib/sampleext/sample_ext_provider.dart'));
      expect((j['externalSeam'] as List), isNotEmpty);
    });

    test('low --budget truncates LAYERS/WIRING but still emits NAMING + TESTS',
        () {
      engine.build(const []);
      final r = Process.runSync('dart',
          [cliSnapshot, 'blueprint', 'lib/features/sample', '--budget', '5']);
      expect(r.exitCode, 0);
      final out = r.stdout as String;
      // The long list is truncated (the … marker appears)…
      expect(out, contains('more (raise --budget'));
      // …yet the planning-critical tail sections still appear.
      expect(out, contains('NAMING CONVENTIONS'));
      expect(out, contains('TESTS:'));
      expect(out, contains('EXTERNAL SEAM'));
      expect(out, contains('ROUTES REGISTERED'));
    });

    test('empty/unknown feature dir → exit 64', () {
      engine.build(const []);
      final r = Process.runSync(
          'dart', [cliSnapshot, 'blueprint', 'lib/features/nope']);
      expect(r.exitCode, 64);
    });
  });

  group('Batch B correctness fixes', () {
    test(
        'callchain refuses an ambiguous callee AT THE DEPTH CAP (d==0), not '
        'just mid-tree', () {
      engine.build(const []);
      // chainAmbigEntry -> chainDupTarget, and chainDupTarget is declared by
      // two unrelated classes in two different files. At --depth 1 the
      // callee lands exactly at the depth cap (the common leaf position) -
      // the bug let the ambiguity gate skip there and silently resolve to
      // decls.first (the alphabetically-first declaring file).
      final j = Process.runSync('dart', [
        cliSnapshot,
        'callchain',
        'chainAmbigEntry',
        '--depth',
        '1',
        '--json',
      ]);
      expect(j.exitCode, 0);
      final root = (jsonDecode(j.stdout as String)
          as Map<String, dynamic>)['roots'] as List;
      final entry = (root.first as Map<String, dynamic>);
      expect(entry['name'], 'chainAmbigEntry');
      final leaf = (entry['calls'] as List).first as Map<String, dynamic>;
      expect(leaf['name'], 'chainDupTarget');
      expect(leaf['ambiguous'], 2,
          reason: 'two same-named declarations at the leaf position must '
              'refuse, not silently pick decls.first');
      expect(leaf.containsKey('site'), isFalse,
          reason: 'an ambiguous callee must not carry a resolved file:line');

      final text = Process.runSync('dart',
          [cliSnapshot, 'callchain', 'chainAmbigEntry', '--depth', '1']);
      expect(text.exitCode, 0);
      final out = text.stdout as String;
      expect(out, contains('ambiguous'));
      // Neither declaring file must be printed as if it were the resolved
      // site - that was the silent-wrong-answer bug.
      expect(out, isNot(contains('chain_ambig_a.dart')));
      expect(out, isNot(contains('chain_ambig_b.dart')));
    });

    test(
        'impls Shape includes a mixin\'s `on` clause and an extension '
        'type\'s `implements` clause', () {
      engine.build(const []);
      final r =
          Process.runSync('dart', [cliSnapshot, 'impls', 'Shape', '--json']);
      expect(r.exitCode, 0);
      final results = (jsonDecode(r.stdout as String)
          as Map<String, dynamic>)['results'] as List;
      final subtypes =
          results.cast<Map<String, dynamic>>().map((e) => e['subtype']);
      expect(subtypes, contains('FixMixinGuard'),
          reason: 'a mixin\'s `on` clause is a stated supertype fact and '
              'must produce an implements/extends edge like a class does');
      expect(subtypes, contains('ShapeBox'),
          reason: 'an extension type\'s `implements` clause must do the '
              'same');
    });

    test('build surfaces a stderr note when a file has parse errors', () {
      File('lib/broken/broken_file.dart')
        ..parent.createSync(recursive: true)
        // Unbalanced braces: a blatant, unrecoverable syntax error.
        ..writeAsStringSync('class Broken {\n  void oops() {\n');
      final r = Process.runSync('dart', [cliSnapshot, 'build']);
      expect(r.exitCode, 0,
          reason: 'a syntax error in one file must not abort the build');
      expect(r.stderr as String, contains('parse errors'));
      expect(r.stderr as String, contains('lib/broken/broken_file.dart'));
    });
  });

  group('intent verbs (2.0 Batch D)', () {
    test('uses <provider> renders the same reader lines as readers', () {
      engine.build(const []);
      final uses =
          Process.runSync('dart', [cliSnapshot, 'uses', 'homeProvider']);
      expect(uses.exitCode, 0, reason: uses.stderr as String);
      final usesOut = uses.stdout as String;
      final readersOut =
          Process.runSync('dart', [cliSnapshot, 'readers', 'homeProvider'])
              .stdout as String;
      // Every line of the readers card (minus its own caveat trailer) must
      // appear verbatim in the uses output - uses delegates, not reimplements.
      for (final line in readersOut.split('\n')) {
        if (line.isEmpty || line.startsWith('caveat:')) continue;
        expect(usesOut, contains(line));
      }
      expect(usesOut, contains('caveat:'));
    });

    test('uses <Type> renders the transitive subtype tree (impls)', () {
      engine.build(const []);
      final r = Process.runSync('dart', [cliSnapshot, 'uses', 'Shape']);
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      expect(out, contains('Circle -> Shape'));
      expect(out, contains('NamedCircle -> Circle'));
    });

    test('uses <function> renders the call sites callers finds', () {
      engine.build(const []);
      final r = Process.runSync('dart', [cliSnapshot, 'uses', 'pingTarget']);
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      expect(out, contains('callers of pingTarget'));
      expect(out, contains('lib/calls/caller_a.dart'));
      expect(out, contains('lib/calls/caller_b.dart'));
      // The refs pointer, so tear-offs/type uses aren't silently absent.
      expect(out, contains('refs pingTarget'));
    });

    test('uses <file> shows inbound wiring (importers)', () {
      engine.build(const []);
      final r =
          Process.runSync('dart', [cliSnapshot, 'uses', 'home_page.dart']);
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      expect(out, contains('imported-by'));
      expect(out, contains('lib/impact_area/home_page_importer.dart'));
    });

    test('uses on an ambiguous file substring exits 2 with candidates', () {
      engine.build(const []);
      final r = Process.runSync('dart', [cliSnapshot, 'uses', 'dup_base.dart']);
      expect(r.exitCode, 2, reason: r.stdout as String);
      expect(r.stdout as String, contains('"dup_base.dart" is ambiguous'));
    });

    test('change <provider> renders impact, subtype/state, and coverage', () {
      engine.build(const []);
      final r =
          Process.runSync('dart', [cliSnapshot, 'change', 'homeProvider']);
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      expect(out, contains('change homeProvider - pre-change pack'));
      expect(out, contains('impact of homeProvider  (depth 2)'));
      // homeProvider is a plain Provider - no Notifier tree, said explicitly.
      expect(out, contains('subtype tree'));
      expect(out, contains('untested in blast radius'));

      // A Notifier-backed provider expands the ACTUAL subtype tree of its
      // Notifier class plus the state-type follow-up (the expanded shape
      // hint - the canonical missed-subclass failure).
      final c =
          Process.runSync('dart', [cliSnapshot, 'change', 'counterProvider']);
      expect(c.exitCode, 0, reason: c.stderr as String);
      final cOut = c.stdout as String;
      expect(cOut, contains('impact of counterProvider  (depth 2)'));
      expect(cOut, contains('implementers / subtypes of CounterNotifier'));
      expect(cOut, contains('refs CounterState'));
    });

    test('health renders attention sections + unused/untested counts', () {
      engine.build(const []);
      final r = Process.runSync(
        'dart',
        [cliSnapshot, 'health', '--budget', '999'],
      );
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      // An attention section header (shared computation, not a copy).
      expect(out, contains('## Ambiguous providers'));
      // Unused + untested summaries with counts.
      expect(out, matches(RegExp(r'providers with 0 lib consumers \(\d+\):')));
      expect(out, matches(RegExp(r'files nothing imports \(\d+\):')));
      expect(
        out,
        matches(RegExp(r'providers with zero test references \(\d+\):')),
      );
      expect(
        out,
        matches(RegExp(r'files with zero test references \(\d+\):')),
      );
      expect(out, contains('caveat:'));
    });

    test('plan is blueprint under its intent name (identical output)', () {
      engine.build(const []);
      final plan = Process.runSync(
        'dart',
        [cliSnapshot, 'plan', 'lib/features/sample'],
      );
      final blueprint = Process.runSync(
        'dart',
        [cliSnapshot, 'blueprint', 'lib/features/sample'],
      );
      expect(plan.exitCode, 0, reason: plan.stderr as String);
      expect(plan.stdout, blueprint.stdout);
    });

    test('review is diff under its intent name', () {
      engine.build(const []);
      Process.runSync('git', ['init', '-q', '-b', 'main']);
      Process.runSync('git', ['config', 'user.email', 'test@example.com']);
      Process.runSync('git', ['config', 'user.name', 'test']);
      Process.runSync('git', ['add', '-A']);
      Process.runSync('git', [
        'commit',
        '-q',
        '-m',
        'base',
        '--author=test <test@example.com>',
      ]);
      File('lib/home/home_zzz_orphan.dart')
          .writeAsStringSync('class HomeZzzOrphan {}\n// touched\n');

      final r = Process.runSync(
        'dart',
        [cliSnapshot, 'review', '--base', 'main'],
      );
      expect(r.exitCode, 0, reason: r.stderr as String);
      final out = r.stdout as String;
      expect(out, startsWith('diff vs main (merge-base '));
      expect(out, contains('blast radius'));
      expect(out, contains('changed but untested:'));
    });
  });
}

/// path (relative to docs/maps/) -> bytes, for every file under docs/maps/
/// except docs/maps/notes/ — the determinism lock's excluded sidecar dir.
Map<String, List<int>> _snapshotMaps() {
  final root = Directory('docs/maps');
  final out = <String, List<int>>{};
  for (final entry in root.listSync(recursive: true)) {
    if (entry is! File) continue;
    final rel = entry.path.substring(root.path.length + 1);
    if (rel.startsWith('notes/') ||
        rel.startsWith('notes${Platform.pathSeparator}')) {
      continue;
    }
    out[rel] = entry.readAsBytesSync();
  }
  return out;
}
