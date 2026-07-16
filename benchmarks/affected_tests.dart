// Frozen affected-test safety oracle. Ground truth is handwritten below and
// never derived from Codegraph output. Any omitted or extra test fails.
import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/affected_tests.dart';
import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/model.dart';

void _write(Directory root, String path, String source) {
  final file = File('${root.path}/$path')..parent.createSync(recursive: true);
  file.writeAsStringSync(source);
}

void _fixture(Directory root) {
  _write(root, 'pubspec.yaml', '''
name: affected_fixture
environment:
  sdk: ^3.5.0
dependencies:
  flutter:
    sdk: flutter
''');
  _write(root, 'packages/shared/pubspec.yaml', '''
name: shared
environment:
  sdk: ^3.5.0
''');
  _write(root, '.deps/riverpod_annotation/pubspec.yaml', '''
name: riverpod_annotation
environment:
  sdk: ^3.5.0
''');
  _write(root, '.deps/go_router/pubspec.yaml', '''
name: go_router
environment:
  sdk: ^3.5.0
''');
  _write(
    root,
    '.deps/riverpod_annotation/lib/riverpod_annotation.dart',
    '''
library riverpod_annotation;

class Riverpod {
  const Riverpod({this.keepAlive = false});
  final bool keepAlive;
}

const riverpod = Riverpod();
''',
  );
  _write(root, '.deps/go_router/lib/go_router.dart', '''
class GoRouteData {
  const GoRouteData();
  void go(Object context) {}
  void push(Object context) {}
  void replace(Object context) {}
  void pushReplacement(Object context) {}
}
''');
  _write(root, '.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    { "name": "affected_fixture", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "shared", "rootUri": "../packages/shared", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "go_router", "rootUri": "../.deps/go_router", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "riverpod_annotation", "rootUri": "../.deps/riverpod_annotation", "packageUri": "lib/", "languageVersion": "3.5" }
  ]
}
''');
  _write(root, 'lib/core/parser.dart', '''
String parseToken(String input) {
  return input;
}

String formatToken(String input) {
  return '[\$input]';
}
''');
  _write(root, 'lib/feature/controller.dart', '''
import 'package:affected_fixture/core/parser.dart';
String loadToken(String input) => parseToken(input);
''');
  _write(root, 'lib/unrelated.dart', 'int unrelated() => 1;\n');
  _write(root, 'lib/state/session.dart', '''
import 'package:riverpod_annotation/riverpod_annotation.dart';

class Ref {
  void invalidate(Object provider) {}
  void refresh(Object provider) {}
}

@riverpod
String session(Ref ref) {
  return 'active';
}
''');
  _write(root, 'lib/state/session_invalidator.dart', '''
import 'package:affected_fixture/state/session.dart';

void invalidateSession(Ref ref) {
  ref.invalidate(sessionProvider);
}
''');
  _write(root, 'lib/state/session_refresher.dart', '''
import 'package:affected_fixture/state/session.dart';

void refreshSession(Ref ref) {
  ref.refresh(sessionProvider);
}
''');
  _write(root, 'lib/routes/app_paths.dart', '''
class AppPaths {
  static final account = _Path();
}

class _Path {
  final settings = _PathChild();
  String get goRoute => '/account';
  String get path => '/account';
}

class _PathChild {
  String get goRoute => '/account/settings';
  String get path => '/account/settings';
}
''');
  _write(root, 'lib/routes/account_page.dart', 'class AccountPage {}\n');
  _write(root, 'lib/routes/settings_page.dart', 'class SettingsPage {}\n');
  _write(root, 'lib/routes/routes.dart', '''
import 'package:affected_fixture/routes/account_page.dart';
import 'package:affected_fixture/routes/app_paths.dart';
import 'package:affected_fixture/routes/settings_page.dart';

class GoRoute {
  const GoRoute({required this.path, this.builder, this.routes = const []});
  final Object path;
  final Object? builder;
  final List<GoRoute> routes;
}

final routes = [
  GoRoute(
    path: AppPaths.account.goRoute,
    builder: () => AccountPage(),
    routes: [
      GoRoute(
        path: AppPaths.account.settings.goRoute,
        builder: () => SettingsPage(),
      ),
    ],
  ),
];
''');
  _write(root, 'lib/routes/home_navigation.dart', '''
import 'package:affected_fixture/routes/app_paths.dart';

class BuildContext {
  void go(String path) {}
}

void openSettings(BuildContext context) {
  context.go(AppPaths.account.settings.path);
}
''');
  _write(root, 'lib/routes/typed_profile_page.dart', '''
class TypedProfilePage {
  const TypedProfilePage();
}
''');
  _write(root, 'lib/routes/typed_profile_route.dart', '''
import 'package:affected_fixture/routes/typed_profile_page.dart';
import 'package:go_router/go_router.dart';

class TypedProfileRoute extends GoRouteData {
  const TypedProfileRoute();
  TypedProfilePage build(Object context, Object state) =>
      const TypedProfilePage();
}
''');
  _write(root, 'lib/routes/typed_profile_navigation.dart', '''
import 'package:affected_fixture/routes/typed_profile_route.dart';

void openTypedProfile(Object context) {
  const TypedProfileRoute().go(context);
}
''');
  _write(root, 'lib/routes/app_router.dart', '''
Object buildRouter() => GoRouter(
      redirect: (context, state) => null,
    );
''');
  _write(root, 'packages/shared/lib/codec.dart', '''
String decodeShared(String value) => value.trim();
''');
  _write(root, 'lib/feature/package_consumer.dart', '''
import 'package:shared/codec.dart';

String consumeShared(String value) => decodeShared(value);
''');
  _write(root, 'test/parser_test.dart', '''
import 'package:affected_fixture/core/parser.dart';
void main() => parseToken('x');
''');
  _write(root, 'test/controller_test.dart', '''
import 'package:affected_fixture/feature/controller.dart';
void main() => loadToken('x');
''');
  _write(root, 'test/format_test.dart', '''
import 'package:affected_fixture/core/parser.dart';
void main() => formatToken('x');
''');
  _write(root, 'test/support/parser_helper.dart', '''
import 'package:affected_fixture/core/parser.dart';
String helper() => parseToken('x');
''');
  _write(root, 'test/helper_user_test.dart', '''
import 'support/parser_helper.dart';
void main() => helper();
''');
  _write(root, 'test/unrelated_test.dart', '''
import 'package:affected_fixture/unrelated.dart';
void main() => unrelated();
''');
  _write(root, 'test/session_provider_test.dart', '''
import 'package:affected_fixture/state/session.dart';
void main() => session(Ref());
''');
  _write(root, 'test/session_invalidate_test.dart', '''
import 'package:affected_fixture/state/session.dart';
import 'package:affected_fixture/state/session_invalidator.dart';
void main() => invalidateSession(Ref());
''');
  _write(root, 'test/session_refresh_test.dart', '''
import 'package:affected_fixture/state/session.dart';
import 'package:affected_fixture/state/session_refresher.dart';
void main() => refreshSession(Ref());
''');
  _write(root, 'test/routes_test.dart', '''
import 'package:affected_fixture/routes/routes.dart';
void main() => routes.length;
''');
  _write(root, 'test/settings_navigation_test.dart', '''
import 'package:affected_fixture/routes/home_navigation.dart';
void main() => openSettings(BuildContext());
''');
  _write(root, 'test/typed_route_contract_test.dart', '''
import 'package:affected_fixture/routes/typed_profile_route.dart';
void main() => const TypedProfileRoute();
''');
  _write(root, 'test/typed_navigation_test.dart', '''
import 'package:affected_fixture/routes/typed_profile_navigation.dart';
void main() => openTypedProfile(Object());
''');
  _write(root, 'test/app_router_test.dart', '''
import 'package:affected_fixture/routes/app_router.dart';
void main() => buildRouter();
''');
  _write(root, 'packages/shared/test/codec_test.dart', '''
import 'package:shared/codec.dart';
void main() => decodeShared(' value ');
''');
  _write(root, 'test/package_consumer_test.dart', '''
import 'package:affected_fixture/feature/package_consumer.dart';
void main() => consumeShared(' value ');
''');
}

Set<String> _selected(AffectedTestPlan plan) =>
    plan.selected.map((test) => test.file).toSet();

Set<String> _commands(AffectedTestPlan plan) => {
      for (final command in plan.commands)
        '${command.workingDirectory}|${command.argv.join(' ')}',
    };

Future<void> main() async {
  final original = Directory.current;
  final root = Directory.systemTemp.createTempSync('codegraph_affected_bench_');
  try {
    _fixture(root);
    Directory.current = root;
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'oracle@example.com']);
    Process.runSync('git', ['config', 'user.name', 'oracle']);
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
    if (commit.exitCode != 0) {
      throw StateError('could not freeze oracle base: ${commit.stderr}');
    }
    final mergeBase =
        (Process.runSync('git', ['rev-parse', 'HEAD']).stdout as String).trim();
    _write(root, 'lib/core/parser.dart', '''
String parseToken(String input) {
  return input.trim();
}

String formatToken(String input) {
  return '[\$input]';
}
''');
    await engine.buildResolved(const []);
    final graph = Graph.load()!;
    final all = {
      'test/parser_test.dart',
      'test/controller_test.dart',
      'test/format_test.dart',
      'test/helper_user_test.dart',
      'test/unrelated_test.dart',
      'test/session_provider_test.dart',
      'test/session_invalidate_test.dart',
      'test/session_refresh_test.dart',
      'test/routes_test.dart',
      'test/settings_navigation_test.dart',
      'test/typed_route_contract_test.dart',
      'test/typed_navigation_test.dart',
      'test/app_router_test.dart',
      'packages/shared/test/codec_test.dart',
      'test/package_consumer_test.dart',
    };
    final scenarios =
        <String, (List<ChangedPath>, String, Set<String>, String?)>{
      'transitive-production': (
        const [ChangedPath('M', 'lib/core/parser.dart')],
        'targeted',
        {
          'test/parser_test.dart',
          'test/controller_test.dart',
          'test/format_test.dart',
          'test/helper_user_test.dart',
        },
        null,
      ),
      'same-file-symbol-body': (
        const [
          ChangedPath(
            'M',
            'lib/core/parser.dart',
            rangesKnown: true,
            ranges: [
              ChangedLineRange(
                oldStart: 2,
                oldCount: 1,
                newStart: 2,
                newCount: 1,
              ),
            ],
          ),
        ],
        'targeted',
        {
          'test/parser_test.dart',
          'test/controller_test.dart',
          'test/helper_user_test.dart',
        },
        mergeBase,
      ),
      'leaf-production': (
        const [ChangedPath('M', 'lib/feature/controller.dart')],
        'targeted',
        {'test/controller_test.dart'},
        null,
      ),
      'test-support': (
        const [ChangedPath('M', 'test/support/parser_helper.dart')],
        'targeted',
        {'test/helper_user_test.dart'},
        null,
      ),
      'configuration-expands': (
        const [ChangedPath('M', 'pubspec.yaml')],
        'workspace-expanded',
        all,
        null,
      ),
      'deletion-expands': (
        const [ChangedPath('D', 'lib/core/parser.dart')],
        'workspace-expanded',
        all,
        null,
      ),
      'riverpod-source-provider': (
        const [ChangedPath('M', 'lib/state/session.dart')],
        'targeted',
        {
          'test/session_provider_test.dart',
          'test/session_invalidate_test.dart',
          'test/session_refresh_test.dart',
        },
        null,
      ),
      'riverpod-invalidate-consumer': (
        const [ChangedPath('M', 'lib/state/session_invalidator.dart')],
        'targeted',
        {'test/session_invalidate_test.dart'},
        null,
      ),
      'riverpod-refresh-consumer': (
        const [ChangedPath('M', 'lib/state/session_refresher.dart')],
        'targeted',
        {'test/session_refresh_test.dart'},
        null,
      ),
      'nested-navigation-target': (
        const [ChangedPath('M', 'lib/routes/settings_page.dart')],
        'targeted',
        {
          'test/routes_test.dart',
          'test/settings_navigation_test.dart',
        },
        null,
      ),
      'typed-route-navigation-target': (
        const [ChangedPath('M', 'lib/routes/typed_profile_page.dart')],
        'targeted',
        {
          'test/typed_route_contract_test.dart',
          'test/typed_navigation_test.dart',
        },
        null,
      ),
      'redirect-global-boundary': (
        const [ChangedPath('M', 'lib/routes/app_router.dart')],
        'workspace-expanded',
        all,
        null,
      ),
      'cross-package-runner-grouping': (
        const [ChangedPath('M', 'packages/shared/lib/codec.dart')],
        'targeted',
        {
          'packages/shared/test/codec_test.dart',
          'test/package_consumer_test.dart',
        },
        null,
      ),
    };

    final failures = <String>[];
    final provider = graph.nodes.where(
      (node) =>
          node.isProvider &&
          node.name == 'sessionProvider' &&
          node.declaredIn == 'lib/state/session.dart',
    );
    if (provider.length != 1) {
      failures.add('riverpod-source-provider: declaration was not resolved');
    }
    final providerId =
        provider.isEmpty ? 'provider:sessionProvider' : provider.single.id;
    for (final expected in {
      ('lib/state/session_invalidator.dart', 'invalidates'),
      ('lib/state/session_refresher.dart', 'refreshes'),
    }) {
      final exists = graph.edges.any(
        (edge) =>
            edge.src == 'file:${expected.$1}' &&
            edge.rel == expected.$2 &&
            edge.dst == providerId,
      );
      if (!exists) {
        failures.add(
          'riverpod-${expected.$2}: missing ${expected.$1} -> $providerId',
        );
      }
    }
    final nestedNavigation = graph.edges.any(
      (edge) =>
          edge.src == 'file:lib/routes/home_navigation.dart' &&
          edge.rel == 'navigates-to' &&
          edge.dst == 'file:lib/routes/settings_page.dart',
    );
    if (!nestedNavigation) {
      failures.add('nested-navigation-target: missing navigates-to edge');
    }
    final typedNavigation = graph.edges.any(
      (edge) =>
          edge.src == 'file:lib/routes/typed_profile_navigation.dart' &&
          edge.rel == 'navigates-to' &&
          edge.dst == 'file:lib/routes/typed_profile_page.dart' &&
          edge.confidence == 'resolved',
    );
    if (!typedNavigation) {
      failures.add(
        'typed-route-navigation-target: missing resolved navigates-to edge',
      );
    }
    final expectedCommands = <String, Set<String>>{
      'cross-package-runner-grouping': {
        '.|flutter test test/package_consumer_test.dart',
        'packages/shared|dart test test/codec_test.dart',
      },
      'redirect-global-boundary': {
        '.|flutter test',
        'packages/shared|dart test',
      },
    };
    var targetedSelected = 0;
    var targetedUniverse = 0;
    final stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < 10; iteration++) {
      for (final scenario in scenarios.entries) {
        final plan = buildAffectedTestPlan(
          graph,
          scenario.value.$1,
          mergeBase: scenario.value.$4,
        );
        if (plan.scope != scenario.value.$2) {
          failures.add(
              '${scenario.key}: scope ${plan.scope} != ${scenario.value.$2}');
        }
        final actual = _selected(plan);
        if (actual.difference(scenario.value.$3).isNotEmpty ||
            scenario.value.$3.difference(actual).isNotEmpty) {
          failures.add('${scenario.key}: $actual != ${scenario.value.$3}');
        }
        final expectedCommandSet = expectedCommands[scenario.key];
        if (expectedCommandSet != null &&
            (_commands(plan).difference(expectedCommandSet).isNotEmpty ||
                expectedCommandSet.difference(_commands(plan)).isNotEmpty)) {
          failures.add(
            '${scenario.key}: commands ${_commands(plan)} != $expectedCommandSet',
          );
        }
        final encoded = jsonEncode(plan.toJson(budget: 1));
        final again = jsonEncode(
          buildAffectedTestPlan(
            graph,
            scenario.value.$1,
            mergeBase: scenario.value.$4,
          ).toJson(budget: 1),
        );
        if (encoded != again)
          failures.add('${scenario.key}: nondeterministic JSON');
        if (iteration == 0 && scenario.value.$2 == 'targeted') {
          targetedSelected += actual.length;
          targetedUniverse += all.length;
        }
      }
    }
    stopwatch.stop();
    if (failures.isNotEmpty) {
      stderr.writeln(failures.toSet().join('\n'));
      exitCode = 1;
      return;
    }
    final runs = scenarios.length * 20; // plan + deterministic replay
    final result = {
      'scenarios': scenarios.length,
      'unsafe_misses': 0,
      'exact_set_failures': 0,
      'median_proxy_ms': stopwatch.elapsedMilliseconds / runs,
      'targeted_reduction': 1 - (targetedSelected / targetedUniverse),
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    stdout.writeln('affected-tests oracle: OK');
  } finally {
    Directory.current = original;
    root.deleteSync(recursive: true);
  }
}
