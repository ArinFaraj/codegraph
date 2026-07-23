import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/freshness.dart' as freshness;
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tempDir;
  late Directory originalCwd;

  setUp(() {
    originalCwd = Directory.current;
    tempDir = Directory.systemTemp.createTempSync('codegraph_fresh_');
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;
  });

  tearDown(() {
    freshness.autoRebuild = true;
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  bool graphHasSymbol(String name) {
    final g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    return (g['nodes'] as List).any(
      (n) => ((n as Map)['symbols'] as List? ?? const [])
          .any((s) => (s as Map)['n'] == name),
    );
  }

  void addCanaryClass() {
    File('lib/home/home_page.dart').writeAsStringSync(
      '\nclass FreshnessCanary {}\n',
      mode: FileMode.append,
    );
  }

  test('build stores a content digest that sourceDigest reproduces', () {
    engine.build(const []);
    final g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final stored = (g['stats'] as Map)['sourceDigest'];
    expect(stored, isA<int>());
    expect(stored, engine.sourceDigest(),
        reason: 'digest must be reproducible from unchanged source');
    addCanaryClass();
    expect(engine.sourceDigest(), isNot(stored),
        reason: 'a source edit must change the digest');
  });

  test('build stores a stat digest that statDigest reproduces', () {
    engine.build(const []);
    final g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final stored = (g['stats'] as Map)['statDigest'];
    expect(stored, isA<int>());
    expect(stored, engine.statDigest(),
        reason: 'stat digest must be reproducible from untouched files');
  });

  test(
      'mtime-only touch stays fresh via the content fallback, '
      'without a rebuild', () {
    engine.build(const []);
    final graphFile = File('docs/maps/code_graph.json');
    final before = graphFile.readAsBytesSync();
    final storedStat =
        (jsonDecode(utf8.decode(before))['stats'] as Map)['statDigest'] as int;
    // Rewrite a file with IDENTICAL content: mtime changes, content doesn't.
    sleep(const Duration(milliseconds: 20)); // ensure a distinct mtime
    final f = File('lib/home/home_page.dart');
    f.writeAsStringSync(f.readAsStringSync());
    expect(engine.statDigest(), isNot(storedStat),
        reason: 'the touch must defeat the stat fast path so this test '
            'actually exercises the content fallback');
    final graph = freshness.loadFresh();
    expect(graph, isNotNull);
    expect(graph!.stats['sourceDigest'], engine.sourceDigest(),
        reason: 'content unchanged, so the graph is genuinely fresh');
    expect(graphFile.readAsBytesSync(), before,
        reason: 'a query must never write - no rebuild on mtime churn');
    expect(freshness.lastLoadFresh, isTrue);
  });

  test('loadFresh auto-rebuilds a stale graph', () {
    engine.build(const []);
    addCanaryClass();
    expect(graphHasSymbol('FreshnessCanary'), isFalse,
        reason: 'graph on disk predates the edit');
    final graph = freshness.loadFresh();
    expect(graph, isNotNull);
    expect(graphHasSymbol('FreshnessCanary'), isTrue,
        reason: 'loadFresh must rebuild so the new symbol is visible');
    expect(graph!.stats['sourceDigest'], engine.sourceDigest());
  });

  test('CLI freshness preflight uses the fast syntax rebuild after an edit',
      () async {
    writeFixturePackageConfig(tempDir);
    await engine.buildDefault(const []);
    addCanaryClass();

    await freshness.ensureFreshDefault();

    final g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((g['stats'] as Map)['resolvedBuild'], 0,
        reason: 'ordinary navigation must not pay for a whole resolved pass');
    expect(graphHasSymbol('FreshnessCanary'), isTrue);
  });

  test('CLI freshness upgrades to resolved only when a verb requires it',
      () async {
    engine.build(const [], analysisPolicy: 'auto');
    var g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((g['stats'] as Map)['resolvedBuild'], 0);
    expect((g['stats'] as Map)['analysisPolicy'], 0);

    writeFixturePackageConfig(tempDir);
    await freshness.ensureFreshDefault();

    g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((g['stats'] as Map)['resolvedBuild'], 0,
        reason: 'a normal query keeps the fast graph even after pub get');

    final markdownBefore = {
      for (final file in Directory('docs/maps')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md')))
        file.path: file.readAsBytesSync(),
    };
    await freshness.ensureFreshDefault(requireResolved: true);

    g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((g['stats'] as Map)['resolvedBuild'], 1);
    expect((g['stats'] as Map)['resolvedFiles'], greaterThan(0));
    for (final entry in markdownBefore.entries) {
      expect(File(entry.key).readAsBytesSync(), entry.value,
          reason: 'query-time resolution must not churn ${entry.key}');
    }

    engine.buildRuntime();
    g = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((g['stats'] as Map)['resolvedBuild'], 1,
        reason: 'a queued runtime refresh must not downgrade a fresh '
            'resolved graph');
    expect(File('docs/maps/refactor_index.json').existsSync(), isTrue,
        reason: 'preserving the resolved graph also preserves its exact '
            'refactor identities');
  });

  test('runtime refresh updates only the machine graph', () {
    engine.build(const []);
    final markdownBefore = {
      for (final file in Directory('docs/maps')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md')))
        file.path: file.readAsBytesSync(),
    };

    addCanaryClass();
    engine.buildRuntime();

    expect(graphHasSymbol('FreshnessCanary'), isTrue);
    for (final entry in markdownBefore.entries) {
      expect(File(entry.key).readAsBytesSync(), entry.value,
          reason: '${entry.key} must not churn during an edit-time refresh');
    }
    expect(
      Directory('docs/maps')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp')),
      isEmpty,
      reason: 'atomic graph publication must not leave temporary files',
    );
  });

  test('loadFresh builds when no graph exists yet', () {
    expect(File('docs/maps/code_graph.json').existsSync(), isFalse);
    final graph = freshness.loadFresh();
    expect(graph, isNotNull);
    expect(File('docs/maps/code_graph.json').existsSync(), isTrue);
  });

  test(
      '--no-rebuild skips the digest walk entirely and reports freshness '
      'as unchecked', () {
    engine.build(const []);
    addCanaryClass();
    freshness.autoRebuild = false;
    final graph = freshness.loadFresh();
    expect(graph, isNotNull);
    expect(graphHasSymbol('FreshnessCanary'), isFalse,
        reason: 'no rebuild may happen when autoRebuild is off');
    expect(freshness.freshnessChecked, isFalse,
        reason: 'the flag must skip the walk, not just the rebuild - '
            'freshness is then unknown, never asserted');
    expect(graph!.stats['sourceDigest'], isNot(engine.sourceDigest()),
        reason: 'the returned graph really is the stale one');
  });
}
