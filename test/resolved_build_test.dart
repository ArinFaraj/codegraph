// 3.0 resolved-build harness tests. Stage 1: driving the analyzer's resolved
// element model over the fixture produces the SAME graph as the syntax build
// (extraction is identical until Stage 2's element-checked extractors diverge),
// and the refusal gate fires when a --resolved build has no package_config.
import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/engine.dart' as engine;
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tempDir;
  late Directory originalCwd;

  setUp(() {
    originalCwd = Directory.current;
    tempDir = Directory.systemTemp.createTempSync('codegraph_resolved_');
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;
  });

  tearDown(() {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  test(
      'resolved and syntax produce the same graph modulo confidence tags '
      '(Stage 2 adds trust, never changes structure)', () async {
    writeFixturePackageConfig(tempDir);

    // Same nodes + edges, ignoring the `confidence` field: element identity
    // TAGS edges (resolved vs heuristic) and can catch a few extra readers, but
    // on this fixture (no Ref-typed receivers) it must not otherwise add,
    // remove, or repoint anything. Strips confidence, then compares.
    String structure() {
      final g = jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
          as Map<String, dynamic>;
      for (final e in (g['edges'] as List).cast<Map<String, dynamic>>()) {
        e.remove('confidence');
      }
      return const JsonEncoder.withIndent('  ').convert(g);
    }

    engine.build(const []);
    final syntaxStructure = structure();

    await engine.buildResolved(const []);
    final resolvedStructure = structure();

    expect(resolvedStructure, syntaxStructure);
  });

  test('resolved build actually resolves fixture files (not all fallback)',
      () async {
    writeFixturePackageConfig(tempDir);
    // Self/SDK-only files (no external imports) must resolve; the graph is
    // written, proving the AnalysisContextCollection path ran end to end.
    await engine.buildResolved(const []);
    expect(File('docs/maps/code_graph.json').existsSync(), isTrue);
  });

  test(
      'resolved catches a renamed-Ref reader that syntax misses (Stage 2 '
      'ceiling flip)', () async {
    writeFixturePackageConfig(tempDir);
    // A reader whose receiver is Ref-TYPED but NOT named ref/_ref/widgetRef -
    // the name allow-list is blind to it; the element check sees the static
    // type. Reads an existing fixture provider (homeProvider) so the edge
    // survives the resolver's real-provider gate.
    File('${tempDir.path}/lib/renamed_ref_reader.dart').writeAsStringSync('''
import 'package:riverpod/riverpod.dart';
import 'package:fixture/home/home_provider.dart';

class RenamedRefReader {
  RenamedRefReader(this.bag);
  final Ref bag;
  int go() => bag.watch(homeProvider);
}
''');

    Map<String, dynamic>? watchEdge() {
      final g = jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
          as Map<String, dynamic>;
      return (g['edges'] as List).cast<Map<String, dynamic>>().where((e) {
        return e['rel'] == 'watches' &&
            e['src'] == 'file:lib/renamed_ref_reader.dart';
      }).firstOrNull;
    }

    engine.build(const []);
    expect(watchEdge(), isNull,
        reason: 'syntax name-match must MISS the renamed Ref receiver');

    await engine.buildResolved(const []);
    final edge = watchEdge();
    expect(edge, isNotNull,
        reason: 'resolved must CATCH it by the receiver static type');
    expect(edge!['confidence'], 'resolved',
        reason: 'an element-checked reader edge must be tagged resolved');
  });

  test(
      'subtype edges are element-resolved under resolution, heuristic under '
      'syntax', () async {
    writeFixturePackageConfig(tempDir);

    int resolvedSubtypeEdges() {
      final g = jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
          as Map<String, dynamic>;
      return (g['edges'] as List).where((e) {
        return e['rel'] == 'implements/extends' &&
            e['confidence'] == 'resolved';
      }).length;
    }

    engine.build(const []);
    expect(resolvedSubtypeEdges(), 0,
        reason: 'a syntax build cannot element-confirm any supertype');

    await engine.buildResolved(const []);
    expect(resolvedSubtypeEdges(), greaterThan(0),
        reason: 'resolved must element-confirm in-package supertype edges');
  });
}
