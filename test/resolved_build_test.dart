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
      final stats = g['stats'] as Map<String, dynamic>;
      stats.remove('resolvedBuild');
      stats.remove('analysisPolicy');
      stats.remove('resolvedFiles');
      // Route topology is intentionally resolved-only: syntax emits an
      // explicit unavailable sidecar while resolved emits available/complete.
      // This test compares the legacy graph structure, not that sidecar.
      g.remove('routeIndex');
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
      'resolved typed route-data navigation lands on exact direct page '
      'contracts and syntax mode makes no claim', () async {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/typed/account_page.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
class AccountPage {
  const AccountPage();
}

class WrappedPage {
  const WrappedPage();
}

class BlockPage {
  const BlockPage();
}
''');
    File('${tempDir.path}/lib/typed/account_route.dart').writeAsStringSync('''
import 'package:go_router/go_router.dart';
import 'package:fixture/typed/account_page.dart';

class AccountRoute extends GoRouteData {
  const AccountRoute();
  AccountPage build(Object context, Object state) => const AccountPage();
}

class WrappedRoute extends GoRouteData {
  const WrappedRoute();
  MaterialPage<WrappedPage> buildPage(Object context, Object state) =>
      const MaterialPage(child: WrappedPage());
}

class BlockRoute extends RelativeGoRouteData {
  const BlockRoute();
  BlockPage build(Object context, Object state) {
    return const BlockPage();
  }
}
''');
    File('${tempDir.path}/lib/typed/typed_caller.dart').writeAsStringSync('''
import 'package:fixture/typed/account_route.dart';

void openRoutes(Object context) {
  const AccountRoute().go(context);
  const WrappedRoute().push(context);
  final destination = const BlockRoute();
  destination.replace(context);
}
''');

    List<Map<String, dynamic>> typedEdges() {
      final graph = jsonDecode(
        File('docs/maps/code_graph.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      return (graph['edges'] as List)
          .cast<Map<String, dynamic>>()
          .where((edge) =>
              edge['src'] == 'file:lib/typed/typed_caller.dart' &&
              (edge['rel'] as String).startsWith('navigates'))
          .toList();
    }

    engine.build(const []);
    expect(typedEdges(), isEmpty,
        reason: 'syntax mode cannot prove a typed-route receiver identity');

    await engine.buildResolved(const []);
    final edges = typedEdges();
    expect(
      edges.where((edge) => edge['rel'] == 'navigates').map((e) => e['dst']),
      containsAll(
          ['route:AccountRoute', 'route:WrappedRoute', 'route:BlockRoute']),
    );
    expect(
      edges
          .where((edge) => edge['rel'] == 'navigates-to')
          .map((e) => e['dst'])
          .toSet(),
      {'file:lib/typed/account_page.dart'},
    );
    expect(
      edges
          .where((edge) => edge.containsKey('confidence'))
          .map((e) => e['confidence']),
      everyElement('resolved'),
    );
    expect(
      edges.where((edge) => edge['rel'] == 'navigates').map((e) => e['detail']),
      containsAll([
        'typed-route go',
        'typed-route push',
        'typed-route replace',
      ]),
    );

    final first = File('docs/maps/code_graph.json').readAsBytesSync();
    await engine.buildResolved(const []);
    expect(File('docs/maps/code_graph.json').readAsBytesSync(), first,
        reason: 'typed-route graph edges must be byte-stable');
  });

  test(
      'resolved typed route index preserves stateful branches, nested paths, '
      'navigator ownership, redirects, pages, callers, and topology edges',
      () async {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/route_tree/pages.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
class AppShellPage { const AppShellPage(); }
class HomePage { const HomePage(); }
class DetailsPage { const DetailsPage(); }
class AccountPage { const AccountPage(); }
class LoginPage { const LoginPage(); }
''');
    File('${tempDir.path}/lib/route_tree/routes.dart').writeAsStringSync(r'''
import 'package:fixture/route_tree/pages.dart';
import 'package:go_router/go_router.dart';

final rootNavigatorKey = Object();
final homeNavigatorKey = Object();
final accountNavigatorKey = Object();

@TypedStatefulShellRoute<AppShell>(branches: [
  TypedStatefulShellBranch<HomeBranch>(routes: [
    TypedGoRoute<HomeRoute>(path: '/home', routes: [
      TypedGoRoute<DetailsRoute>(path: 'details/:id'),
      TypedRelativeGoRoute<HelpRoute>(path: 'help'),
    ]),
  ]),
  TypedStatefulShellBranch<AccountBranch>(routes: [
    TypedGoRoute<AccountRoute>(path: '/account', routes: [
      TypedRelativeGoRoute<HelpRoute>(path: 'help'),
    ]),
  ]),
])
class AppShell extends StatefulShellRouteData {
  static final Object $navigatorKey = rootNavigatorKey;
  AppShellPage builder(Object context, Object state, Object child) =>
      const AppShellPage();
}

class HomeBranch extends StatefulShellBranchData {
  static final Object $navigatorKey = homeNavigatorKey;
}

class AccountBranch extends StatefulShellBranchData {
  static final Object $navigatorKey = accountNavigatorKey;
}

class HomeRoute extends GoRouteData {
  const HomeRoute();
  HomePage build(Object context, Object state) => const HomePage();
}

class DetailsRoute extends GoRouteData {
  const DetailsRoute();
  static final Object $parentNavigatorKey = rootNavigatorKey;
  DetailsPage build(Object context, Object state) => const DetailsPage();
  String? redirect(Object context, Object state) => const LoginRoute().location;
}

class AccountRoute extends GoRouteData {
  const AccountRoute();
  AccountPage build(Object context, Object state) => const AccountPage();
}

class HelpRoute extends RelativeGoRouteData {
  const HelpRoute();
  DetailsPage build(Object context, Object state) => const DetailsPage();
}

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData {
  const LoginRoute();
  LoginPage build(Object context, Object state) => const LoginPage();
}
''');
    File('${tempDir.path}/lib/route_tree/caller.dart').writeAsStringSync('''
import 'package:fixture/route_tree/routes.dart';

void openDetails(Object context) {
  const DetailsRoute().go(context);
  const DetailsRoute().push(context);
  const DetailsRoute().replace(context);
  const DetailsRoute().pushReplacement(context);
  const DetailsRoute().goRelative(context);
  const DetailsRoute().pushRelative(context);
}
''');

    await engine.buildResolved(const []);
    final graph = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final index = graph['routeIndex'] as Map<String, dynamic>;
    expect(index['available'], isTrue);
    expect(index['complete'], isTrue);
    final contracts = (index['contracts'] as List).cast<Map<String, dynamic>>();
    expect(contracts, hasLength(9));
    final details = contracts.singleWhere(
      (route) => route['name'] == 'DetailsRoute',
    );
    final shell = contracts.singleWhere((route) => route['name'] == 'AppShell');
    final homeBranch =
        contracts.singleWhere((route) => route['name'] == 'HomeBranch');
    final home = contracts.singleWhere((route) => route['name'] == 'HomeRoute');
    expect(details['path'], 'details/:id');
    expect(details['fullPath'], '/home/details/:id');
    expect(details['parent'], home['id']);
    expect(details['branch'], homeBranch['id']);
    expect(details['shell'], shell['id']);
    expect(details['branchIndex'], 0);
    expect(details['pageFile'], 'lib/route_tree/pages.dart');
    expect(details['parentNavigatorKey'],
        'package:fixture/route_tree/routes.dart::rootNavigatorKey');
    expect(details['navigatorOwner'], shell['id']);
    expect(details['redirectDeclared'], isTrue);
    expect(details['redirectComplete'], isTrue);
    expect(details['redirectTargets'], [
      'package:fixture/route_tree/routes.dart::LoginRoute',
    ]);
    expect(details['uncertainties'], isNull);
    final helpPlacements =
        contracts.where((route) => route['name'] == 'HelpRoute').toList();
    expect(helpPlacements, hasLength(2));
    expect(
      helpPlacements.map((route) => route['fullPath']).toSet(),
      {'/home/help', '/account/help'},
      reason: 'a reusable relative route must keep both placements',
    );
    expect(
      helpPlacements.map((route) => route['symbol']).toSet(),
      {'package:fixture/route_tree/routes.dart::HelpRoute'},
    );

    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    final typedCalls = edges
        .where((edge) =>
            edge['src'] == 'file:lib/route_tree/caller.dart' &&
            edge['rel'] == 'navigates')
        .toList();
    expect(typedCalls.map((edge) => edge['operation']).toSet(), {
      'go',
      'push',
      'replace',
      'pushReplacement',
      'goRelative',
      'pushRelative',
    });
    expect(
      typedCalls.map((edge) => edge['routeSymbol']).toSet(),
      {'package:fixture/route_tree/routes.dart::DetailsRoute'},
    );
    expect(
      edges.any((edge) =>
          edge['src'] == details['navigationId'] &&
          edge['rel'] == 'builds' &&
          edge['dst'] == 'file:lib/route_tree/pages.dart'),
      isTrue,
    );
    expect(
      edges.any((edge) =>
          edge['src'] == details['navigationId'] &&
          edge['rel'] == 'redirects-to' &&
          edge['dst'] == 'route:LoginRoute'),
      isTrue,
    );

    final first = File('docs/maps/code_graph.json').readAsBytesSync();
    await engine.buildResolved(const []);
    expect(File('docs/maps/code_graph.json').readAsBytesSync(), first,
        reason: 'resolved route topology must be byte-deterministic');
  });

  test('typed route extraction refuses fake bases and non-exact page bodies',
      () async {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/typed/refusal_page.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
class RefusalPage {
  const RefusalPage();
}
''');
    File('${tempDir.path}/lib/typed/refusal_routes.dart').writeAsStringSync('''
import 'package:go_router/go_router.dart' as real;
import 'package:fixture/typed/refusal_page.dart';

class GoRouteData {
  void go(Object context) {}
}

class FakeRoute extends GoRouteData {
  RefusalPage build(Object context, Object state) => const RefusalPage();
}

class ConditionalRoute extends real.GoRouteData {
  const ConditionalRoute();
  RefusalPage build(Object context, Object state, bool condition) {
    if (condition) return const RefusalPage();
    return const RefusalPage();
  }
}

void openRefused(Object context) {
  FakeRoute().go(context);
  const ConditionalRoute().go(context);
}
''');

    await engine.buildResolved(const []);
    final graph = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final edges = (graph['edges'] as List)
        .cast<Map<String, dynamic>>()
        .where((edge) => edge['src'] == 'file:lib/typed/refusal_routes.dart')
        .toList();
    expect(edges.where((edge) => edge['dst'] == 'route:FakeRoute'), isEmpty,
        reason: 'same spelling outside package:go_router must be ignored');
    final conditional = edges.singleWhere(
      (edge) =>
          edge['rel'] == 'navigates' && edge['dst'] == 'route:ConditionalRoute',
    );
    expect(conditional['unresolved'], isTrue);
    expect(
      edges.where((edge) =>
          edge['rel'] == 'navigates-to' &&
          edge['dst'] == 'file:lib/typed/refusal_page.dart'),
      isEmpty,
      reason: 'multi-return bodies must not be guessed into page edges',
    );
  });

  test('same-named typed routes in different packages keep element identity',
      () async {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/typed/host_page.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class HostPage { const HostPage(); }\n');
    File('${tempDir.path}/lib/typed/duplicate_route.dart').writeAsStringSync('''
import 'package:fixture/typed/host_page.dart';
import 'package:go_router/go_router.dart';

class DuplicateRoute extends GoRouteData {
  const DuplicateRoute();
  HostPage build(Object context, Object state) => const HostPage();
}
''');
    File('${tempDir.path}/lib/typed/duplicate_caller.dart')
        .writeAsStringSync('''
import 'package:fixture/typed/duplicate_route.dart';
void openHost(Object context) => const DuplicateRoute().go(context);
''');
    File('${tempDir.path}/packages/fixture_ui/lib/package_page.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class PackagePage { const PackagePage(); }\n');
    File('${tempDir.path}/packages/fixture_ui/lib/duplicate_route.dart')
        .writeAsStringSync('''
import 'package:fixture_ui/package_page.dart';
import 'package:go_router/go_router.dart';

class DuplicateRoute extends GoRouteData {
  const DuplicateRoute();
  PackagePage build(Object context, Object state) => const PackagePage();
}
''');
    File('${tempDir.path}/packages/fixture_ui/lib/duplicate_caller.dart')
        .writeAsStringSync('''
import 'package:fixture_ui/duplicate_route.dart';
void openPackage(Object context) => const DuplicateRoute().push(context);
''');

    await engine.buildResolved(const []);
    final graph = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    final hostNavigation = edges.singleWhere(
      (edge) =>
          edge['src'] == 'file:lib/typed/duplicate_caller.dart' &&
          edge['rel'] == 'navigates',
    );
    final packageNavigation = edges.singleWhere(
      (edge) =>
          edge['src'] == 'file:packages/fixture_ui/lib/duplicate_caller.dart' &&
          edge['rel'] == 'navigates',
    );
    expect(
      hostNavigation['dst'],
      'route:DuplicateRoute@package:fixture/typed/duplicate_route.dart',
    );
    expect(
      packageNavigation['dst'],
      'route:DuplicateRoute@package:fixture_ui/duplicate_route.dart',
    );
    expect(
      edges.any((edge) =>
          edge['src'] == 'file:lib/typed/duplicate_caller.dart' &&
          edge['rel'] == 'navigates-to' &&
          edge['dst'] == 'file:lib/typed/host_page.dart'),
      isTrue,
    );
    expect(
      edges.any((edge) =>
          edge['src'] == 'file:packages/fixture_ui/lib/duplicate_caller.dart' &&
          edge['rel'] == 'navigates-to' &&
          edge['dst'] == 'file:packages/fixture_ui/lib/package_page.dart'),
      isTrue,
    );
  });

  test(
      'resolved refactor index is complete, deterministic, and syntax builds '
      'invalidate it', () async {
    writeFixturePackageConfig(tempDir);
    await engine.buildResolved(const []);
    final index = File('docs/maps/refactor_index.json');
    expect(index.existsSync(), isTrue);
    final first = index.readAsBytesSync();
    final decoded =
        jsonDecode(index.readAsStringSync()) as Map<String, dynamic>;
    expect(decoded['resolvedFiles'], decoded['totalFiles']);
    expect(decoded['declarations'], isNotEmpty);
    expect(decoded['references'], isNotEmpty);

    await engine.buildResolved(const []);
    expect(index.readAsBytesSync(), first,
        reason: 'identical source must produce an identical refactor index');

    engine.build(const []);
    expect(index.existsSync(), isFalse,
        reason: 'syntax-only analysis cannot retain semantic edit identities');
  });

  test('resolved index and freshness include local-package tests', () async {
    writeFixturePackageConfig(tempDir);
    final packageTest = File(
      '${tempDir.path}/packages/fixture_ui/test/fancy_button_test.dart',
    )
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:fixture_ui/fancy_button.dart';

void main() {
  FancyButton.icon('test').press();
}
''');

    await engine.buildResolved(const []);
    final index = jsonDecode(
      File('docs/maps/refactor_index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(index['resolvedFiles'], index['totalFiles']);
    expect(
      (index['references'] as List)
          .cast<Map<String, dynamic>>()
          .map((reference) => reference['file']),
      contains('packages/fixture_ui/test/fancy_button_test.dart'),
    );
    final digest = index['sourceDigest'];
    packageTest.writeAsStringSync('\n// changed\n', mode: FileMode.append);
    expect(engine.sourceDigest(), isNot(digest));
    expect(
        engine.statDigest(),
        isNot(
          (jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
              as Map<String, dynamic>)['stats']['statDigest'],
        ));
  });

  test(
      'resolved catches renamed and wrapper-held Ref readers that syntax '
      'misses (Stage 2 ceiling flip)', () async {
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

class RefBox {
  RefBox(this.ref);
  final Ref ref;
}

class WrappedRefReader {
  WrappedRefReader(this.box);
  final RefBox box;
  int go() => box.ref.read(homeProvider);
}
''');

    Map<String, dynamic>? readerEdge(String rel) {
      final g = jsonDecode(File('docs/maps/code_graph.json').readAsStringSync())
          as Map<String, dynamic>;
      return (g['edges'] as List).cast<Map<String, dynamic>>().where((e) {
        return e['rel'] == rel &&
            e['src'] == 'file:lib/renamed_ref_reader.dart';
      }).firstOrNull;
    }

    engine.build(const []);
    expect(readerEdge('watches'), isNull,
        reason: 'syntax name-match must miss the renamed Ref receiver');
    expect(readerEdge('reads'), isNull,
        reason: 'syntax name-match must miss a wrapper-held Ref receiver');

    await engine.buildResolved(const []);
    final watch = readerEdge('watches');
    final read = readerEdge('reads');
    expect(watch, isNotNull,
        reason: 'resolved must CATCH it by the receiver static type');
    expect(read, isNotNull,
        reason: 'resolved must follow the wrapper field static type');
    expect(watch!['confidence'], 'resolved',
        reason: 'an element-checked reader edge must be tagged resolved');
    expect(read!['confidence'], 'resolved',
        reason: 'an element-checked reader edge must be tagged resolved');
  });

  test(
      'resolved build models source-declared @riverpod providers without '
      'reading generated files', () async {
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/annotated_providers.dart').writeAsStringSync('''
import 'dart:async';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

@riverpod
Future<int> user(Ref ref) async => 1;

@Riverpod(keepAlive: true)
Stream<int> activity(Ref ref) => const Stream.empty();

abstract class _\$GeneratedCounter {}
@riverpod
class GeneratedCounter extends _\$GeneratedCounter {
  int build() => 0;
}

void consume(Ref ref) {
  ref.watch(userProvider);
  ref.watch(activityProvider);
  ref.watch(generatedCounterProvider);
  ref.invalidate(userProvider);
  ref.refresh(activityProvider);
}
''');
    File('${tempDir.path}/lib/annotation_decoy.dart').writeAsStringSync('''
class FakeRiverpod {
  const FakeRiverpod();
}
const riverpod = FakeRiverpod();

@riverpod
int impostor() => 0;
''');

    await engine.buildResolved(const []);
    final graph = jsonDecode(
      File('docs/maps/code_graph.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> provider(String name) => nodes.firstWhere(
          (node) => node['kind'] == 'provider' && node['name'] == name,
        );

    expect(provider('userProvider')['providerType'], 'FutureProvider');
    expect(provider('userProvider')['autoDispose'], isTrue);
    expect(provider('activityProvider')['providerType'], 'StreamProvider');
    expect(provider('activityProvider')['autoDispose'], isFalse);
    expect(provider('generatedCounterProvider')['providerType'],
        'NotifierProvider');
    expect(provider('generatedCounterProvider')['autoDispose'], isTrue);
    expect(
      nodes.where(
        (node) =>
            node['kind'] == 'provider' && node['name'] == 'impostorProvider',
      ),
      isEmpty,
      reason: 'annotation spelling alone must never create a provider',
    );

    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    expect(
      edges
          .where((edge) => edge['rel'] == 'watches')
          .map((edge) => edge['dst']),
      containsAll([
        'provider:userProvider',
        'provider:activityProvider',
        'provider:generatedCounterProvider',
      ]),
    );
    expect(
      edges
          .where((edge) => edge['rel'] == 'invalidates')
          .map((edge) => edge['dst']),
      contains('provider:userProvider'),
    );
    expect(
      edges
          .where((edge) => edge['rel'] == 'refreshes')
          .map((edge) => edge['dst']),
      contains('provider:activityProvider'),
    );
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
