// Executable mutation oracle for resolved typed-route impact.
//
// Unlike the set-only affected-tests benchmark, this freezes a passing fixture,
// applies a real source mutation, runs every test executable to discover the
// actual failing set, then proves Codegraph selected a superset (and the exact
// frozen expected set). A zero here therefore means zero omitted failing tests
// for the covered mutation, not merely agreement with handwritten labels.
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
name: route_mutation_fixture
environment:
  sdk: ^3.5.0
''');
  _write(root, '.deps/go_router/lib/go_router.dart', '''
class GoRouteData {
  const GoRouteData();
  void go(Object context) {}
  String get location => '/';
}

class TypedGoRoute<T extends GoRouteData> {
  const TypedGoRoute({required this.path, this.routes = const []});
  final String path;
  final List<Object> routes;
}
''');
  _write(root, '.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    { "name": "route_mutation_fixture", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "go_router", "rootUri": "../.deps/go_router", "packageUri": "lib/", "languageVersion": "3.5" }
  ]
}
''');
  _write(root, 'lib/pages/details_page.dart', '''
class DetailsPage {
  const DetailsPage();
  String label() => 'details-v1';
}
''');
  _write(root, 'lib/routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:route_mutation_fixture/pages/details_page.dart';

@TypedGoRoute<DetailsRoute>(path: '/details')
class DetailsRoute extends GoRouteData {
  const DetailsRoute();
  DetailsPage build(Object context, Object state) => const DetailsPage();
}
''');
  _write(root, 'lib/navigation.dart', '''
import 'package:route_mutation_fixture/routes.dart';

String openDetails(Object context) {
  const DetailsRoute().go(context);
  return const DetailsRoute().build(context, Object()).label();
}
''');
  _write(root, 'lib/unrelated.dart', 'int unrelated() => 1;\n');
  _write(root, 'test/details_page_test.dart', '''
import 'package:route_mutation_fixture/pages/details_page.dart';
void main() {
  if (const DetailsPage().label() != 'details-v1') throw StateError('page');
}
''');
  _write(root, 'test/details_route_test.dart', '''
import 'package:route_mutation_fixture/routes.dart';
void main() {
  if (const DetailsRoute().build(Object(), Object()).label() != 'details-v1') {
    throw StateError('route');
  }
}
''');
  _write(root, 'test/details_navigation_test.dart', '''
import 'package:route_mutation_fixture/navigation.dart';
void main() {
  if (openDetails(Object()) != 'details-v1') throw StateError('navigation');
}
''');
  _write(root, 'test/unrelated_test.dart', '''
import 'package:route_mutation_fixture/unrelated.dart';
void main() {
  if (unrelated() != 1) throw StateError('unrelated');
}
''');
}

Set<String> _runTests(Directory root, List<String> tests) {
  final failing = <String>{};
  for (final test in tests) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      [test],
      workingDirectory: root.path,
    );
    if (result.exitCode != 0) failing.add(test);
  }
  return failing;
}

Future<void> main() async {
  final original = Directory.current;
  final root = Directory.systemTemp.createTempSync('codegraph_route_mutation_');
  const tests = [
    'test/details_page_test.dart',
    'test/details_route_test.dart',
    'test/details_navigation_test.dart',
    'test/unrelated_test.dart',
  ];
  const expected = {
    'test/details_page_test.dart',
    'test/details_route_test.dart',
    'test/details_navigation_test.dart',
  };
  try {
    _fixture(root);
    Directory.current = root;
    final baselineFailures = _runTests(root, tests);
    if (baselineFailures.isNotEmpty) {
      throw StateError('oracle baseline is not green: $baselineFailures');
    }
    Process.runSync('git', ['init', '-q', '-b', 'main']);
    Process.runSync('git', ['config', 'user.email', 'oracle@example.com']);
    Process.runSync('git', ['config', 'user.name', 'oracle']);
    Process.runSync('git', ['add', '-A']);
    final commit = Process.runSync(
      'git',
      ['-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'baseline'],
      environment: {'GIT_CONFIG_GLOBAL': '/dev/null'},
    );
    if (commit.exitCode != 0) {
      throw StateError('could not freeze mutation baseline: ${commit.stderr}');
    }

    _write(root, 'lib/pages/details_page.dart', '''
class DetailsPage {
  const DetailsPage();
  String label() => 'details-v2';
}
''');
    final actualFailing = _runTests(root, tests);
    await engine.buildResolved(const []);
    final graph = Graph.load()!;
    final plan = buildAffectedTestPlan(
      graph,
      const [ChangedPath('M', 'lib/pages/details_page.dart')],
    );
    final selected = plan.selected.map((test) => test.file).toSet();
    final unsafeMisses = actualFailing.difference(selected);
    final extraOrMissing = selected.difference(expected).union(
          expected.difference(selected),
        );
    if (actualFailing.difference(expected).isNotEmpty ||
        expected.difference(actualFailing).isNotEmpty) {
      throw StateError(
        'mutation no longer produces the frozen failing set: '
        '$actualFailing != $expected',
      );
    }
    if (plan.scope != 'targeted' ||
        unsafeMisses.isNotEmpty ||
        extraOrMissing.isNotEmpty) {
      throw StateError(
        'route mutation failed: scope=${plan.scope}, selected=$selected, '
        'failing=$actualFailing, unsafe=$unsafeMisses, delta=$extraOrMissing',
      );
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'scenarios': 1,
      'actual_test_executions': tests.length * 2,
      'failing_tests': actualFailing.length,
      'selected_tests': selected.length,
      'unsafe_misses': unsafeMisses.length,
      'exact_set_failures': extraOrMissing.length,
      'targeted_reduction': 1 - (selected.length / tests.length),
    }));
    stdout.writeln('route mutation oracle: OK');
  } finally {
    Directory.current = original;
    root.deleteSync(recursive: true);
  }
}
