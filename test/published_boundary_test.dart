// The publishedPackages boundary gate - the first conformance rule mined from
// a reproducible benchmark failure (Stage A campaign 2026-07-18: both agent
// arms renamed a published package's public API despite a prose warning). The
// boundary must be graph-consumable data: with `codegraph.json` declaring a
// package published, rename REFUSES its public API; without the config the
// same rename proceeds (the graph alone cannot know about external
// consumers); private symbols inside the package stay renameable either way.
import 'dart:io';

import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/rename.dart' as rename;
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory tempDir;
  late Directory originalCwd;

  setUp(() {
    originalCwd = Directory.current;
    tempDir = Directory.systemTemp.createTempSync('codegraph_pub_');
    writeCodegraphFixture(tempDir);
    writeFixturePackageConfig(tempDir);
    Directory.current = tempDir;
    engine.build(const []);
  });

  tearDown(() {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  test('rename refuses public API of a declared published package', () async {
    File('${tempDir.path}/codegraph.json')
        .writeAsStringSync('{"publishedPackages": ["fixture_ui"]}');
    final before =
        File('${tempDir.path}/packages/fixture_ui/lib/fancy_button.dart')
            .readAsStringSync();
    final code =
        await rename.run(['rename', 'FancyButton.press', 'tap', '--apply']);
    expect(code, 3, reason: 'published public API must refuse (exit 3)');
    expect(
        File('${tempDir.path}/packages/fixture_ui/lib/fancy_button.dart')
            .readAsStringSync(),
        before,
        reason: 'a refusal must leave the package untouched');
  });

  test('the same rename proceeds without the publishedPackages config',
      () async {
    final code = await rename.run(['rename', 'FancyButton.press', 'tap']);
    expect(code, 0,
        reason: 'without the config the boundary fact does not exist; '
            'dry-run must answer normally');
  });

  test('the INDEXED path enforces the same boundary', () async {
    File('${tempDir.path}/codegraph.json')
        .writeAsStringSync('{"publishedPackages": ["fixture_ui"]}');
    // A resolved build writes the refactor index; rename then takes the
    // graph-speed path, which must refuse identically to the cold path.
    await engine.buildResolved(const []);
    final code =
        await rename.run(['rename', 'FancyButton.press', 'tap', '--apply']);
    expect(code, 3);
  });
}
