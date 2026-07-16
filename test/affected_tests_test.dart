import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory originalCwd;
  late Directory temp;
  late String cliSnapshot;

  setUpAll(() {
    originalCwd = Directory.current;
    cliSnapshot =
        '${Directory.systemTemp.createTempSync('codegraph_affected_cli_').path}/cli.dill';
    final compile = Process.runSync('dart', [
      'compile',
      'kernel',
      '${originalCwd.path}/bin/codegraph.dart',
      '-o',
      cliSnapshot,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('could not compile CLI: ${compile.stderr}');
    }
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('codegraph_affected_');
    writeCodegraphFixture(temp);
    Directory.current = temp;
    File('test/support/home_helper.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:fixture/home/home_helper.dart';

String exerciseHomeHelper() => formatHomeTitle('test');
''');
    File('test/helper_user_test.dart').writeAsStringSync('''
import 'support/home_helper.dart';

void main() => exerciseHomeHelper();
''');
    File('packages/fixture_ui/test/fancy_button_test.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:fixture_ui/fancy_button.dart';

void main() => FancyButton.icon('test');
''');
    File('lib/semantic_tools.dart').writeAsStringSync('''
String parseToken(String input) {
  return input.trim();
}

String formatToken(String input) {
  return '[\$input]';
}
''');
    File('test/parse_token_test.dart').writeAsStringSync('''
import 'package:fixture/semantic_tools.dart';

void main() => parseToken(' test ');
''');
    File('test/format_token_test.dart').writeAsStringSync('''
import 'package:fixture/semantic_tools.dart';

void main() => formatToken('test');
''');
  });

  tearDown(() {
    Directory.current = originalCwd;
    temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> plan(List<String> args) {
    final result = Process.runSync(
      'dart',
      [cliSnapshot, 'affected-tests', ...args, '--json'],
    );
    expect(result.exitCode, 0, reason: result.stderr as String);
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  Set<String> selected(Map<String, dynamic> json) => (json['selected'] as List)
      .map((entry) => (entry as Map<String, dynamic>)['file'] as String)
      .toSet();

  test('selects runnable tests through production and test-helper closures',
      () {
    final json = plan(['lib/home/home_helper.dart']);
    expect(json['scope'], 'targeted');
    expect(selected(json), {'test/helper_user_test.dart'});
    expect(
      (json['selected'] as List).single['reasons'],
      contains('imports affected lib/home/home_helper.dart'),
    );
  });

  test('a changed test helper selects its importing entrypoint, not itself',
      () {
    final json = plan(['test/support/home_helper.dart']);
    expect(json['scope'], 'targeted');
    expect(selected(json), {'test/helper_user_test.dart'});
    expect(selected(json), isNot(contains('test/support/home_helper.dart')));
  });

  test('provider changes follow production consumers and direct test imports',
      () {
    final json = plan(['lib/home/home_provider.dart']);
    expect(json['scope'], 'targeted');
    expect(selected(json), contains('test/home_test.dart'));
    expect(json['uncertainties'], isEmpty);
  });

  test('multi-hop barrel changes select the runnable barrel test', () {
    final json = plan(['lib/barrel/impl.dart']);
    expect(json['scope'], 'targeted');
    expect(selected(json), contains('test/barrel_test.dart'));
    expect(selected(json), isNot(contains('test/cycle_test.dart')));
  });

  test('local-package tests receive their own working directory and argv', () {
    final json = plan(['packages/fixture_ui/lib/fancy_button.dart']);
    expect(json['scope'], 'targeted');
    expect(selected(json), {'packages/fixture_ui/test/fancy_button_test.dart'});
    final command = (json['commands'] as List).single as Map<String, dynamic>;
    expect(command['workingDirectory'], 'packages/fixture_ui');
    expect(command['argv'], [
      'dart',
      'test',
      'test/fancy_button_test.dart',
    ]);
  });

  test('deleted production input expands to the complete runnable suite', () {
    File('lib/home/home_helper.dart').deleteSync();
    final json = plan(['lib/home/home_helper.dart']);
    expect(json['scope'], 'workspace-expanded');
    expect(
      (json['uncertainties'] as List).join('\n'),
      contains('old dependency edges are unavailable'),
    );
    expect(selected(json),
        containsAll({'test/home_test.dart', 'test/cycle_test.dart'}));
    expect(selected(json), isNot(contains('test/harness_part.dart')));
  });

  test('generated boundaries and global route policy expand with reason codes',
      () {
    File('lib/generated/model.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('@freezed\nclass Model {}\n');
    final generated = plan(['lib/generated/model.dart']);
    expect(generated['scope'], 'workspace-expanded');
    expect(
      (generated['expansions'] as List)
          .map((entry) => (entry as Map<String, dynamic>)['code']),
      contains('generated_boundary'),
    );

    File('lib/routing/app_router.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('final router = GoRouter(routes: []);\n');
    final routing = plan(['lib/routing/app_router.dart']);
    expect(routing['scope'], 'workspace-expanded');
    expect(
      (routing['expansions'] as List)
          .map((entry) => (entry as Map<String, dynamic>)['code']),
      contains('global_route'),
    );
  });

  test('unmapped test support and parse errors fail open', () {
    final part = plan(['test/harness_part.dart']);
    expect(part['scope'], 'workspace-expanded');
    expect(
      (part['uncertainties'] as List).join('\n'),
      contains('zero runnable test entrypoints'),
    );

    File('lib/broken.dart').writeAsStringSync('class {\n');
    final broken = plan(['lib/broken.dart']);
    expect(broken['scope'], 'workspace-expanded');
    expect(
      (broken['expansions'] as List)
          .map((entry) => (entry as Map<String, dynamic>)['code']),
      contains('partial_parse'),
    );
  });

  test('global configuration expands and JSON is never budget-truncated', () {
    final json = plan(['pubspec.yaml', '--budget', '1']);
    expect(json['scope'], 'workspace-expanded');
    expect(json.containsKey('truncated'), isFalse);
    expect((json['selected'] as List).length, greaterThan(1));
    expect((json['selected'] as List).length, json['selectedCount']);
    expect((json['commands'] as List), isNotEmpty);
  });

  test('--no-rebuild can only produce a fail-open workspace plan', () {
    // First write a graph, then explicitly opt out of checking it.
    final first = plan(['lib/home/home_helper.dart']);
    expect(first['scope'], 'targeted');
    final result = Process.runSync('dart', [
      cliSnapshot,
      'affected-tests',
      'lib/home/home_helper.dart',
      '--no-rebuild',
      '--json',
    ]);
    expect(result.exitCode, 0, reason: result.stderr as String);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['scope'], 'workspace-expanded');
    expect(
      (json['uncertainties'] as List).join('\n'),
      contains('freshness was not proven'),
    );
  });

  test('git mode uses merge-base changes and ignores generated map artifacts',
      () {
    plan(['lib/home/home_helper.dart']); // ensure the graph exists first
    File('.gitignore').writeAsStringSync('docs/maps/\n.dart_tool/\n');
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'test@example.com']);
    Process.runSync('git', ['config', 'user.name', 'test']);
    Process.runSync('git', ['add', '-A']);
    final commit = Process.runSync('git', [
      '-c',
      'commit.gpgsign=false',
      'commit',
      '-q',
      '-m',
      'base',
    ], environment: {
      'GIT_CONFIG_GLOBAL': '/dev/null'
    });
    expect(commit.exitCode, 0, reason: commit.stderr as String);
    File('lib/home/home_helper.dart')
        .writeAsStringSync('\n// changed\n', mode: FileMode.append);

    final json = plan(['--base', 'main']);
    expect(json['scope'], 'targeted');
    expect(
      (json['changed'] as List)
          .map((change) => (change as Map<String, dynamic>)['path']),
      ['lib/home/home_helper.dart'],
    );
    expect(selected(json), {'test/helper_user_test.dart'});
  });

  test('git body hunks select only tests observing the changed symbol', () {
    writeFixturePackageConfig(temp);
    plan(['lib/semantic_tools.dart']); // write the resolved graph and index
    File('.gitignore').writeAsStringSync('docs/maps/\n.dart_tool/\n');
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'test@example.com']);
    Process.runSync('git', ['config', 'user.name', 'test']);
    Process.runSync('git', ['add', '-A']);
    final commit = Process.runSync('git', [
      '-c',
      'commit.gpgsign=false',
      'commit',
      '-q',
      '-m',
      'base',
    ], environment: {
      'GIT_CONFIG_GLOBAL': '/dev/null'
    });
    expect(commit.exitCode, 0, reason: commit.stderr as String);
    File('lib/semantic_tools.dart').writeAsStringSync('''
String parseToken(String input) {
  return input.trim().toUpperCase();
}

String formatToken(String input) {
  return '[\$input]';
}
''');

    final json = plan(['--base', 'main']);
    final refactor = jsonDecode(
      File('docs/maps/refactor_index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final graph = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(json['scope'], 'targeted');
    expect(
      json['semanticAttribution'],
      isTrue,
      reason: jsonEncode({
        'plan': json,
        'indexTotal': refactor['totalFiles'],
        'indexResolved': refactor['resolvedFiles'],
        'indexDigest': refactor['sourceDigest'],
        'graphDigest': (graph['stats'] as Map)['sourceDigest'],
      }),
    );
    expect(selected(json), {'test/parse_token_test.dart'});
    expect(selected(json), isNot(contains('test/format_token_test.dart')));
    expect(
      (json['changeAttribution'] as List).single['mode'],
      'resolved-symbol',
    );
    expect(json['precisionFallbacks'], isEmpty);

    File('lib/semantic_tools.dart').writeAsStringSync('''
String parseToken(Object input) {
  return input.toString().trim();
}

String formatToken(String input) {
  return '[\$input]';
}
''');
    final structural = plan(['--base', 'main']);
    expect(structural['semanticAttribution'], isFalse);
    expect(
      selected(structural),
      {'test/parse_token_test.dart', 'test/format_token_test.dart'},
    );
    expect(
      (structural['precisionFallbacks'] as List).join('\n'),
      contains('stable executable body boundary'),
    );
  });
}
