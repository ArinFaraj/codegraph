import 'dart:io';

/// Writes a minimal `.dart_tool/package_config.json` for the fixture so
/// `engine.buildResolved` can run the analyzer's resolved element model over
/// it (3.0). Maps the two local packages (`fixture`, `fixture_ui`); the SDK is
/// found from the running Dart. External packages the fixture names (go_router)
/// are intentionally absent - those files resolve self/SDK types and leave the
/// external symbols unresolved, exercising the per-file partial-resolution path
/// without vendoring real dependencies.
void writeFixturePackageConfig(Directory root) {
  // Minimal resolvable stand-in for go_router, placed OUTSIDE the scanned roots
  // (`.fixture_deps/`, not `packages/*`) so codegraph never adds it to the graph
  // but the analyzer can resolve `GoRoute` to a real class. That makes the
  // fixture's `GoRoute(...)` parse as an InstanceCreationExpression under
  // resolution (a MethodInvocation under syntax) - the exact fork the engine's
  // dual GoRoute extraction must handle identically. Permissive params: unknown
  // named args still classify the call as a constructor, so leniency only
  // reduces diagnostic noise.
  File('${root.path}/.fixture_deps/go_router/lib/go_router.dart')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
class GoRoute {
  GoRoute({
    Object? path,
    Object? name,
    Object? builder,
    Object? pageBuilder,
    Object? routes,
    Object? redirect,
    Object? parentNavigatorKey,
  });
}
''');
  // Resolvable Ref/WidgetRef so a receiver's STATIC TYPE can be checked (3.0
  // Stage 2 element-checked readers). Also outside scanned roots.
  File('${root.path}/.fixture_deps/riverpod/lib/riverpod.dart')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
class Ref {
  T watch<T>(Object provider) => throw '';
  T read<T>(Object provider) => throw '';
  void listen(Object provider, Object onChange) {}
}
class WidgetRef extends Ref {}
class ProviderContainer {
  T read<T>(Object provider) => throw '';
}
class Notifier<T> {
  T build() => throw '';
}
''');
  File('${root.path}/.dart_tool/package_config.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    { "name": "fixture", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "fixture_ui", "rootUri": "../packages/fixture_ui", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "go_router", "rootUri": "../.fixture_deps/go_router", "packageUri": "lib/", "languageVersion": "3.5" },
    { "name": "riverpod", "rootUri": "../.fixture_deps/riverpod", "packageUri": "lib/", "languageVersion": "3.5" }
  ]
}
''');
}

void writeCodegraphFixture(Directory root) {
  void write(String rel, String content) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.5.0\n');
  write(
    'packages/fixture_ui/pubspec.yaml',
    'name: fixture_ui\nenvironment:\n  sdk: ^3.5.0\n',
  );
  write('packages/fixture_ui/lib/fancy_button.dart', '''
/// A fancy button widget.
class FancyButton {
  FancyButton.icon(String label);

  void press() {}
}
''');
  write(
    'packages/fixture_ui/lib/format.dart',
    'String formatLabel(String raw, {bool upper = false}) => raw;\n',
  );
  write(
    'lib/home/home_provider.dart',
    'final homeProvider = Provider<int>((ref) => 1);\n',
  );
  write('lib/home/home_page.dart', '''
import 'package:fixture_ui/fancy_button.dart';
import 'package:fixture/home/home_provider.dart';

class HomePage {
  void build(dynamic ref, dynamic context) {
    ref.watch(homeProvider);
    context.go('/details');
    FancyButton();
  }
}
''');

  // Imported by both home_reader_a.dart and home_reader_b.dart below — the
  // 2-importer fixture for ranked-find (in-degree 2 must outrank a
  // 0-in-degree match with the same "home" substring).
  write('lib/home/home_helper.dart', '''
/// Formats a home-screen title.
String formatHomeTitle(String raw) => raw;
''');
  write('lib/home/home_reader_a.dart', '''
import 'package:fixture/home/home_helper.dart';

class HomeReaderA {
  void build() => formatHomeTitle('a');
}
''');
  write('lib/home/home_reader_b.dart', '''
import 'package:fixture/home/home_helper.dart';

class HomeReaderB {
  void build() => formatHomeTitle('b');
}
''');
  // 0-in-degree file that also matches the "home" substring, so the ranked
  // find test can assert it sorts AFTER home_helper.dart (in-degree 2).
  write('lib/home/home_zzz_orphan.dart', 'class HomeZzzOrphan {}\n');

  // Same provider name declared twice, in two unrelated files — the
  // duplicate-name case (see the "duplicate provider names" test above).
  write(
    'lib/dup/a_provider.dart',
    'final dupProvider = Provider<int>((ref) => 1);\n',
  );
  write(
    'lib/dup/b_provider.dart',
    'final dupProvider = Provider<int>((ref) => 2);\n',
  );
  write('lib/dup/a_reader.dart', '''
import 'package:fixture/dup/a_provider.dart';

class AReader {
  void build(dynamic ref) => ref.watch(dupProvider);
}
''');
  write('lib/dup/b_reader.dart', '''
import 'package:fixture/dup/b_provider.dart';

class BReader {
  void build(dynamic ref) => ref.watch(dupProvider);
}
''');

  // Duplicate CLASS names — ClassResolver refuse-or-narrow (0.9.4 usefulness).
  write('lib/ambig/a/dup_base.dart', 'class DupBase {}\n');
  write('lib/ambig/b/dup_base.dart', 'class DupBase {}\n');
  write('lib/ambig/c/user.dart', 'class DupUser extends DupBase {}\n');
  write('lib/ambig/d/narrowed.dart', '''
import 'package:fixture/ambig/a/dup_base.dart';

class NarrowedUser extends DupBase {}
''');

  // Provider with one watcher AND one reader, for the readers --json
  // --budget test (total items across sections must respect the budget).
  write(
    'lib/budget/budget_provider.dart',
    'final budgetProvider = Provider<int>((ref) => 1);\n',
  );
  write('lib/budget/budget_watcher.dart', '''
import 'package:fixture/budget/budget_provider.dart';

class BudgetWatcher {
  void build(dynamic ref) => ref.watch(budgetProvider);
}
''');
  write('lib/budget/budget_reader.dart', '''
import 'package:fixture/budget/budget_provider.dart';

class BudgetReader {
  void build(dynamic ref) => ref.read(budgetProvider);
}
''');

  // A file imported by 12 importer files — fan-in fixture for the brief
  // line-length cap test (a long uncapped `imported-by` join would otherwise
  // produce a 700+ char line).
  write('lib/fanin/fanin_target.dart', 'class FaninTarget {}\n');
  for (var i = 0; i < 12; i++) {
    write('lib/fanin/fanin_importer_$i.dart', '''
import 'package:fixture/fanin/fanin_target.dart';

class FaninImporter$i {
  void build() => FaninTarget();
}
''');
  }

  // --- 0.7.0 Stage 1: lint fixtures -----------------------------------
  // Two feature units under lib/features/. auth_page imports vault_page
  // (CROSS-unit → cross-feature-import fires); auth_page also imports
  // auth_helper (SAME unit → does NOT fire). Both files end `_page.dart`
  // (role view), so the crossing import is a view→view import — NOT in
  // layersForbid, so it isolates the cross-feature rule from layer-order.
  write('lib/features/auth/auth_page.dart', '''
import 'package:fixture/features/vault/vault_page.dart';
import 'package:fixture/features/auth/auth_helper.dart';

class AuthPage {
  void build() {
    VaultPage();
    authHelper();
  }
}
''');
  write('lib/features/auth/auth_helper.dart', 'void authHelper() {}\n');
  write('lib/features/vault/vault_page.dart', 'class VaultPage {}\n');

  // layer-order: a repository-role file importing a view-role file is a
  // FORBIDDEN direction (repository -> view) → fires, with the import line.
  // A view importing a repository is the ALLOWED direction → does NOT fire.
  // Kept OUT of lib/features/ so it never trips cross-feature-import.
  write('lib/lintlayer/thing_repository.dart', '''
import 'package:fixture/lintlayer/thing_page.dart';

class ThingRepository {
  void build() => ThingPage();
}
''');
  write('lib/lintlayer/thing_page.dart', 'class ThingPage {}\n');
  write('lib/lintlayer/other_page.dart', '''
import 'package:fixture/lintlayer/other_repository.dart';

class OtherPage {
  void build() => OtherRepository();
}
''');
  write('lib/lintlayer/other_repository.dart', 'class OtherRepository {}\n');

  // --- 0.7.0 Stage 2: rules 3-4 fixtures ------------------------------
  // Rule 3 (banned-provider-kind): a StateProvider declared in a file whose
  // role IS an allowed provider home (provider), so it isolates rule 3 from
  // rule 4. Fires ONLY when StateProvider is in banned_provider_kinds.
  write('lib/lintprov/banned_provider.dart',
      'final lintBannedProvider = StateProvider<int>((ref) => 1);\n');
  // Rule 4 (provider-placement): a plain Provider declared in a _page.dart
  // (role view) — view is NOT a provider home, so placement fires when
  // provider_homes is configured. Kept out of lib/features/ (cross-feature)
  // and it's a plain Provider (not a banned kind) to isolate rule 4.
  write('lib/lintprov/misplaced_page.dart',
      'final lintMisplacedProvider = Provider<int>((ref) => 1);\n');

  // Barrel importing the three lint top-importers so they aren't orphans
  // (keeps the shared fixture's orphan/ATTENTION assertions stable). Named
  // *_routes.dart so it is itself orphan-exempt.
  write('lib/lintbarrel/lint_routes.dart', '''
export 'package:fixture/features/auth/auth_page.dart';
export 'package:fixture/lintlayer/thing_repository.dart';
export 'package:fixture/lintlayer/other_page.dart';
''');

  // extension type — must produce a symbol record (kind ext-type) instead of
  // being silently dropped.
  write(
    'lib/sig/meters.dart',
    'extension type Meters(double value) {}\n',
  );

  // static method / operator / factory constructor / sealed class — sig
  // rendering coverage (each must appear verbatim in the emitted sig).
  write('lib/sig/shapes.dart', '''
sealed class Shape {
  static Shape unit() => Circle(1);

  factory Shape.fromRadius(double r) => Circle(r);
}

class Circle extends Shape {
  Circle(this.radius);

  final double radius;

  Circle operator +(Circle other) => Circle(radius + other.radius);
}

// A grandchild so `impls Shape` can be checked for TRANSITIVE closure
// (Shape -> Circle -> NamedCircle), not just direct subtypes.
class NamedCircle extends Circle {
  NamedCircle(super.radius, this.name);
  final String name;
}

// mixin `on` clause capture: a stated, syntax-visible supertype constraint
// that must show up under `impls Shape` same as extends/implements does.
// Declared in the SAME file as Shape (not a new one) so the frozen
// subtype-tree benchmark truth ({'lib/sig/shapes.dart'}) is unchanged.
mixin FixMixinGuard on Shape {}

// extension type `implements` clause capture - same doctrine, same edge path.
extension type ShapeBox(Circle c) implements Shape {}
''');

  // 13 public methods — exercises uncapped memberIndex for `find` past the
  // 12-member render cap.
  write('lib/sig/many_members.dart', '''
class ManyMembers {
  void m01() {}
  void m02() {}
  void m03() {}
  void m04() {}
  void m05() {}
  void m06() {}
  void m07() {}
  void m08() {}
  void m09() {}
  void m10() {}
  void m11() {}
  void m12() {}
  void m13() {}
}
''');

  // --- Stage 1: test-reference pass fixtures ---------------------------

  // Zero lib consumers but referenced (token-matched) from a test file below
  // — the `· test-only (N test refs)` case for `unused`/ATTENTION.
  write(
    'lib/testonly/testonly_provider.dart',
    'final testOnlyProvider = Provider<int>((ref) => 1);\n',
  );

  // Un-referenced (by lib AND test) view-role file — must show up under
  // `untested files` (and, being unimported, also under `unused files`).
  // Own area (not lib/home) so it doesn't perturb the `lib/home` file-count
  // assertions elsewhere in this suite.
  write(
    'lib/untested_area/untested_view_page.dart',
    'class UntestedViewPage {}\n',
  );

  // test/ root: resolves a lib import (home_provider.dart -> fileTestRefs)
  // and token-matches homeProvider + testOnlyProvider in source text
  // (providerTestRefs) — the `homeProvider` reference proves testRefs lands
  // on a node that ALSO has real lib consumers, `testOnlyProvider` proves
  // the test-only case. Both are also imported directly here, so this
  // fixture satisfies the 0.6.0 Stage 3 closure gate as well as the older
  // bare-token rule — it does not by itself distinguish the two; see the
  // dedicated closure-gate fixtures below (unreachableProvider,
  // barrelGatedProvider) for that.
  //
  // unreachableProvider: mentioned in a comment only, its declaring file
  // (lib/closuregate/unreachable_provider.dart) is never imported here or by
  // any other test file — must NOT be credited under the closure gate.
  write('test/home_test.dart', '''
import 'package:fixture/home/home_provider.dart';
import 'package:fixture/testonly/testonly_provider.dart';

void main() {
  // token references only — no test framework needed for this fixture.
  homeProvider;
  testOnlyProvider;
  // mentions unreachableProvider without importing its declaring file.
}
''');

  // A.2: export-closure fixtures for `_scanTestRefs` — a test importing an
  // export-only barrel must credit both the barrel AND whatever it
  // (transitively) exports.
  //
  // Direct case: barrel.dart is export-only (no import), re-exporting
  // impl.dart. barrel_test.dart imports ONLY barrel.dart.
  write('lib/barrel/impl.dart', '''
final barrelImplProvider = Provider<int>((ref) => 1);
''');
  write('lib/barrel/barrel.dart', '''
export 'package:fixture/barrel/impl.dart';
''');
  // A lib importer keeps barrel.dart/chain_top.dart out of the "files
  // nothing imports" orphan section below — this fixture is about testRefs
  // export-following, not orphan detection, and an unrelated new orphan
  // would perturb the fixed-cap ATTENTION.md/find ordering tests elsewhere
  // in this suite.
  write('lib/barrel/barrel_and_chain_importer.dart', '''
import 'package:fixture/barrel/barrel.dart';
import 'package:fixture/barrel/chain_top.dart';
import 'package:fixture/closuregate/unreachable_provider.dart';
import 'package:fixture/closuregate/barrel_gated_barrel.dart';
import 'package:fixture/closuregate/part_inherited_provider.dart';
import 'package:fixture/closuregate/part_not_imported_provider.dart';
import 'package:fixture/notif/counter_provider.dart';
import 'package:fixture/notif/counter_ref_ext.dart';
import 'package:fixture/notif/counter_container_reader.dart';
import 'package:fixture/calls/caller_a.dart';
import 'package:fixture/calls/caller_b.dart';
import 'package:fixture/chain/chain_flow.dart';

class BarrelAndChainImporter {
  void build() {
    barrelImplProvider;
    ChainLeaf;
    unreachableProvider;
    barrelGatedProvider;
    partInheritedProvider;
    partNotImportedProvider;
    counterProvider;
    CounterRefX;
    readCounterViaContainer;
    a();
    b();
    chainEntry(true);
  }
}
''');

  // A Notifier-backed provider (+ its notifier class and state type) so
  // `readers counterProvider` can be checked for the shape-change hint that
  // points at `impls CounterNotifier` / `sym CounterState`.
  write('lib/notif/counter_provider.dart', '''
class CounterState {
  const CounterState(this.value);
  final int value;
}

class CounterNotifier extends AsyncNotifier<CounterState> {
  @override
  Future<CounterState> build() async => const CounterState(0);
}

final counterProvider =
    AsyncNotifierProvider<CounterNotifier, CounterState>(
  CounterNotifier.new,
  name: 'counterProvider',
);
''');

  // An `extension on Ref` that reads counterProvider via BARE read/watch/listen
  // (implicit `this`-is-the-Ref receiver) — these were invisible before the
  // Ref-extension fix; readers must now credit this file.
  write('lib/notif/counter_ref_ext.dart', '''
import 'package:fixture/notif/counter_provider.dart';

extension CounterRefX on Ref {
  int get counterValue => read(counterProvider).valueOrNull?.value ?? 0;
  void watchCounter() => watch(counterProvider);
  void onCounter() => listen(counterProvider, (a, b) {});
}
''');

  // ProviderContainer.read — the bootstrap/dialog/dev pattern
  // (`container.read(provider)`), a distinct receiver from `ref` (its OWN file
  // so `readers` crediting it isolates container detection).
  write('lib/notif/counter_container_reader.dart', '''
import 'package:fixture/notif/counter_provider.dart';

int readCounterViaContainer(ProviderContainer container) =>
    container.read(counterProvider).valueOrNull?.value ?? 0;
''');

  // Cascade-form ref reads: `ref..listen(p)..read(q)`. Each cascade section has
  // a null `target` (the receiver lives on the CascadeExpression), so these were
  // invisible until reader detection switched to `realTarget` — the keep-alive
  // `..listen(deviceTokenProvider, (_, _) {})` pattern showed zero-consumer.
  write('lib/notif/counter_cascade_reader.dart', '''
import 'package:fixture/notif/counter_provider.dart';

class CounterCascadeReader {
  void wire(WidgetRef ref) {
    ref
      ..listen(counterProvider, (a, b) {})
      ..read(counterProvider);
  }
}
''');

  // NEGATIVE (refusal gate): a cascade `..listen(...)` on a NON-ref receiver must
  // NOT be an edge — `realTarget` resolves to `_Bag()`, which the `_refReceivers`
  // gate rejects, so switching to realTarget adds ONLY genuine ref cascades.
  write('lib/notif/non_ref_cascade.dart', '''
import 'package:fixture/notif/counter_provider.dart';

class _Bag {
  void listen(Object p, void Function(Object, Object) cb) {}
}

void notARead() {
  _Bag()..listen(counterProvider, (a, b) {});
}
''');

  // callchain fixture: chainEntry -> chainMid (early-return guard) ->
  // chainLeaf (empty/swallowing catch).
  write('lib/chain/chain_flow.dart', '''
void chainEntry(bool x) => chainMid(x);
void chainMid(bool x) {
  if (x) return;
  chainLeaf();
}
void chainLeaf() {
  try {
    chainEntry(false);
  } catch (e) {}
}
''');

  // callchain ambiguity-at-depth-cap regression fixture: two unrelated
  // classes in different files declare the SAME method name, and the caller
  // reaches that name at the walk's last hop (depth cap). `callchain` resolves
  // callees by NAME only, so `chainDupTarget` must refuse (ambiguous) here
  // just like it would at any other depth - never silently pick whichever
  // file happened to parse/sort first.
  write('lib/chain/chain_ambig_a.dart', '''
class ChainAmbigA {
  void chainDupTarget() {}
}
''');
  write('lib/chain/chain_ambig_b.dart', '''
class ChainAmbigB {
  void chainDupTarget() {}
}
''');
  write('lib/chain/chain_ambig_entry.dart', '''
void chainAmbigEntry() {
  ChainAmbigA().chainDupTarget();
}
''');

  // callers/refs fixture: `pingTarget` is CALLED from two files + torn off once;
  // its own declaration must not be listed as a call.
  write('lib/calls/target.dart', 'void pingTarget() {}\n');
  write('lib/calls/caller_a.dart', '''
import 'package:fixture/calls/target.dart';
void a() => pingTarget();
''');
  write('lib/calls/caller_b.dart', '''
import 'package:fixture/calls/target.dart';
void b() {
  pingTarget();
  final f = pingTarget; // tear-off (a `ref`, not a `call`)
  f();
}
''');
  write('test/barrel_test.dart', '''
import 'package:fixture/barrel/barrel.dart';

void main() {
  barrelImplProvider;
}
''');

  // Two-hop case: chain_test.dart imports chain_top.dart, which only
  // exports chain_mid.dart, which only exports chain_leaf.dart — the leaf
  // must still get credited (BFS, not single-hop).
  write('lib/barrel/chain_leaf.dart', '''
class ChainLeaf {}
''');
  write('lib/barrel/chain_mid.dart', '''
export 'package:fixture/barrel/chain_leaf.dart';
''');
  write('lib/barrel/chain_top.dart', '''
export 'package:fixture/barrel/chain_mid.dart';
''');
  write('test/chain_test.dart', '''
import 'package:fixture/barrel/chain_top.dart';

void main() {
  ChainLeaf;
}
''');

  // Cyclic export pair: cycle_a.dart exports cycle_b.dart and vice versa —
  // the BFS closure must terminate (cycle-guarded) and still credit both
  // files for a test that imports either one.
  write('lib/barrel/cycle_a.dart', '''
export 'package:fixture/barrel/cycle_b.dart';

class CycleA {}
''');
  write('lib/barrel/cycle_b.dart', '''
export 'package:fixture/barrel/cycle_a.dart';

class CycleB {}
''');
  write('test/cycle_test.dart', '''
import 'package:fixture/barrel/cycle_a.dart';

void main() {
  CycleA;
  CycleB;
}
''');

  // 0.6.0 Stage 3: closure-gated testRefs fixtures. Both declaring files
  // below are imported from lib by barrel_and_chain_importer.dart (added to
  // its import list further down) purely to keep them off the "files
  // nothing imports" orphan section — this fixture is about testRefs
  // closure-gating from a TEST file's perspective, not orphan detection,
  // and an unrelated new orphan would perturb the fixed-cap ATTENTION.md/
  // find ordering tests elsewhere in this suite.
  //
  // (a) mentioned, not imported (by any TEST file): unreachableProvider's
  // declaring file is never imported (directly or via a barrel) from
  // test/ — home_test.dart mentions its name in a comment only, which must
  // NOT credit it under the new closure gate (the old bare-token-match rule
  // would have).
  write(
    'lib/closuregate/unreachable_provider.dart',
    'final unreachableProvider = Provider<int>((ref) => 1);\n',
  );

  // (b) mentioned, reached via a barrel (from a TEST file): barrelGatedProvider
  // is declared in a file only reachable through barrel_gated_barrel.dart's
  // export closure — barrel_gated_test.dart imports the barrel (not the
  // declaring file directly) and mentions the name, which must credit it.
  write(
    'lib/closuregate/barrel_gated_provider.dart',
    'final barrelGatedProvider = Provider<int>((ref) => 1);\n',
  );
  write('lib/closuregate/barrel_gated_barrel.dart', '''
export 'package:fixture/closuregate/barrel_gated_provider.dart';
''');
  write('test/barrel_gated_test.dart', '''
import 'package:fixture/closuregate/barrel_gated_barrel.dart';

void main() {
  barrelGatedProvider;
}
''');

  // 0.6.0 Stage 3b: part-file import inheritance. A `part` file carries no
  // import directives of its own — they live on the library (`part of`)
  // file and are shared by every part. `harness.dart` is the library file:
  // it imports partInheritedProvider's declaring file and has
  // `part 'harness_part.dart';`. The reference to partInheritedProvider
  // lives ONLY inside harness_part.dart, which has NO imports of its own
  // (just `part of 'harness.dart';`) — under a naive per-file closure gate
  // this reference would be dropped; it must instead be credited via the
  // parent library's imports.
  write(
    'lib/closuregate/part_inherited_provider.dart',
    'final partInheritedProvider = Provider<int>((ref) => 1);\n',
  );
  // Negative control, same shape: partNotImportedProvider's declaring file
  // is never imported by harness.dart (or anything else in test/), so the
  // part-file reference to it must NOT be credited. Both declaring files
  // are imported by barrel_and_chain_importer.dart above (kept off the
  // "files nothing imports" orphan list for the same reason as the other
  // closuregate providers there).
  write(
    'lib/closuregate/part_not_imported_provider.dart',
    'final partNotImportedProvider = Provider<int>((ref) => 1);\n',
  );
  write('test/harness.dart', '''
import 'package:fixture/closuregate/part_inherited_provider.dart';

part 'harness_part.dart';
''');
  write('test/harness_part.dart', '''
part of 'harness.dart';

void useHarness() {
  partInheritedProvider;
  partNotImportedProvider;
}
''');

  // --- Stage 2: impact fixtures -----------------------------------------

  // A two-hop import chain: home_page_importer.dart imports home_page.dart
  // directly (depth 1 from home_page.dart), and home_page_reimporter.dart
  // imports home_page_importer.dart (depth 2 from home_page.dart) — the
  // `impact` depth-1-vs-depth-2 fixture. Own area (not lib/home) so it
  // doesn't perturb the `lib/home` file-count assertions elsewhere in this
  // suite.
  write('lib/impact_area/home_page_importer.dart', '''
import 'package:fixture/home/home_page.dart';

class HomePageImporter {
  void build() => HomePage();
}
''');
  write('lib/impact_area/home_page_reimporter.dart', '''
import 'package:fixture/impact_area/home_page_importer.dart';

class HomePageReimporter {
  void build() => HomePageImporter();
}
''');

  // --- Stage 4: navigation resolution fixtures ---------------------------
  //
  // Mirrors a common navigation shape (route path constants as
  // `AppPaths`-style chained objects, `GoRoute(path:, builder:/pageBuilder:)`
  // declarations, builders that directly instantiate a page widget): a
  // static `AppPaths`-style route-chain class (here a plain class with
  // static getters — the fixture doesn't need the real go_router_paths
  // package, just the `AppPaths.<chain>` SOURCE TEXT the matcher keys on), a
  // `GoRoute(path: AppPaths.details.goRoute, builder: ...)` declaration
  // whose builder instantiates the page class, and a `context.go(...)`
  // caller using the matching `AppPaths.details.path` chain — the one
  // pattern Stage 4 resolves (single-hop, syntax-only, no dataflow: a
  // navigates expression is matched to a GoRoute's path, then to the
  // builder's resolved page type, never guessed).
  write('lib/routing/app_paths.dart', '''
class AppPaths {
  static _Details get details => _Details();
  static _Wrapped get wrapped => _Wrapped();
  static _Constant get constant => _Constant();
  static _Helper get helper => _Helper();
  static _Helper2 get helper2 => _Helper2();
  static _Named get named => _Named();
  static _MaterialWrap get materialWrap => _MaterialWrap();
  static _NestedWrap get nestedWrap => _NestedWrap();
  static _DupHelper get dupHelper => _DupHelper();
  static _Tearoff get tearoff => _Tearoff();
  static _SelfConst get selfConst => _SelfConst();
}

class _Details {
  String get goRoute => 'details';
  String get path => '/details';
}

class _Wrapped {
  String get goRoute => 'wrapped';
  String get path => '/wrapped';
}

class _Constant {
  String get goRoute => 'constant';
  String get path => '/constant';
}

class _Helper {
  String get goRoute => 'helper';
  String get path => '/helper';
}

class _Helper2 {
  String get goRoute => 'helper2';
  String get path => '/helper2';
}

class _Named {
  String get goRoute => 'named';
  String get path => '/named';
}

class _MaterialWrap {
  String get goRoute => 'material-wrap';
  String get path => '/material-wrap';
}

class _NestedWrap {
  String get goRoute => 'nested-wrap';
  String get path => '/nested-wrap';
}

class _DupHelper {
  String get goRoute => 'dup-helper';
  String get path => '/dup-helper';
}

class _Tearoff {
  String get goRoute => 'tearoff';
  String get path => '/tearoff';
}

class _SelfConst {
  String get goRoute => 'self-const';
  String get path => '/self-const';
}
''');
  write('lib/routing/details_page.dart', '''
class DetailsPage {
  const DetailsPage();
}
''');
  write('lib/routing/app_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/details_page.dart';

final appRoutes = [
  GoRoute(
    path: AppPaths.details.goRoute,
    builder: (context, state) => const DetailsPage(),
  ),
];
''');
  // Resolvable caller: `AppPaths.details.path` normalizes to the same
  // `AppPaths.details` root as the GoRoute's `AppPaths.details.goRoute` ->
  // must produce a navigates-to edge landing on details_page.dart.
  write('lib/routing/details_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class DetailsCaller {
  void build(dynamic context) {
    context.go(AppPaths.details.path);
  }
}
''');
  // Unresolvable caller: a local variable, not an `AppPaths.` chain — the
  // matcher must never guess, so this must NOT produce a navigates-to edge
  // even though a (plain, unresolved) navigates edge is still recorded.
  write('lib/routing/dynamic_caller.dart', '''
class DynamicCaller {
  void build(dynamic context, String dest) {
    context.go(dest);
  }
}
''');

  // Same-line collision fixture (the FIX 1/FIX 2 regression): one resolvable
  // nav and one unresolvable nav on the SAME physical line. Before the flag
  // became authoritative, both `navLines` and `_unresolvedNavigation` joined
  // `navigates` to `navigates-to` by (src, line) alone, so the resolvable
  // sibling's target line would get borrowed by the unresolvable call (or
  // vice versa). `GraphEdge.unresolved` is per-edge, so each call must render
  // correctly even though they share a line.
  write('lib/routing/collision_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class CollisionCaller {
  void build(dynamic context, bool c, dynamic someUnresolvableVar) {
    if (c) { context.go(AppPaths.details.path); } else { context.go(someUnresolvableVar); }
  }
}
''');

  // Two-resolvable-on-one-line fixture: both calls resolve, but the (src,
  // line) join can't tell which target belongs to which call — must render
  // "(resolved, ambiguous line)" rather than guessing either target.
  write('lib/routing/ambiguous_line_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class AmbiguousLineCaller {
  void build(dynamic context, bool c) {
    if (c) { context.go(AppPaths.details.path); } else { context.go(AppPaths.constant.path); }
  }
}
''');

  // Wrapped-builder GoRoute (the never-guess regression fixture, see
  // engine.dart's `_firstCreatedType` doc comment): the builder's top-level
  // call is `AnalyticsWrapper(...)`, not the page — even though `WrappedPage`
  // is constructed one level down as an argument. A path-matching caller
  // must still get NO navigates-to edge; the page file must not appear as
  // anyone's target.
  write('lib/routing/wrapped_page.dart', '''
class WrappedPage {
  const WrappedPage();
}
''');
  write('lib/routing/analytics_wrapper.dart', '''
class AnalyticsWrapper {
  const AnalyticsWrapper({required this.child});
  final dynamic child;
}
''');
  write('lib/routing/wrapped_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/analytics_wrapper.dart';
import 'package:fixture/routing/wrapped_page.dart';

final wrappedRoutes = [
  GoRoute(
    path: AppPaths.wrapped.goRoute,
    builder: (context, state) =>
        const AnalyticsWrapper(child: WrappedPage()),
  ),
];
''');
  write('lib/routing/wrapped_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class WrappedCaller {
  void build(dynamic context) {
    context.go(AppPaths.wrapped.path);
  }
}
''');

  // --- Mechanism (a): route-constant substitution fixtures ---------------
  //
  // Mirrors a common `final enterUpnRoute =
  // AppPaths.language.info.enterUpn;` shape
  // (lib/onboarding/routing/onboarding_routes.dart): a top-level constant
  // whose GoRoute uses `constant.goRoute` and whose caller uses
  // `constant.path` — both must resolve to the SAME page through the
  // constant table.
  write('lib/routing/constant_page.dart', '''
class ConstantPage {
  const ConstantPage();
}
''');
  write('lib/routing/constant_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/constant_page.dart';

final constantRoute = AppPaths.constant;

final constantRoutes = [
  GoRoute(
    path: constantRoute.goRoute,
    builder: (context, state) => const ConstantPage(),
  ),
];
''');
  write('lib/routing/constant_caller.dart', '''
import 'package:fixture/routing/constant_routes.dart';

class ConstantCaller {
  void build(dynamic context) {
    context.go(constantRoute.path);
  }
}
''');

  // Duplicate constant name, different chains, in an unrelated file — the
  // REFUSAL GATE: `dupRoute` must be dropped from the table entirely, so a
  // caller using it gets NO navigates-to edge even though the name matches
  // one of the two declarations.
  write('lib/routing/dup_const_a.dart', 'final dupRoute = AppPaths.details;\n');
  write(
    'lib/routing/dup_const_b.dart',
    'final dupRoute = AppPaths.wrapped;\n',
  );
  write('lib/routing/dup_const_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/dup_const_a.dart';
import 'package:fixture/routing/dup_const_b.dart';

class DupConstCaller {
  void build(dynamic context) {
    context.go(dupRoute.path);
  }
}
''');

  // Constant-of-constant (2-hop): `hopB` references `hopA`, which is the
  // `AppPaths.` root. A GoRoute keyed on `hopB.goRoute` and a caller keyed on
  // `hopB.path` must both resolve within the depth-3 cap.
  write('lib/routing/two_hop.dart', '''
import 'package:fixture/routing/app_paths.dart';

final hopA = AppPaths.constant;
final hopB = hopA;
''');
  write('lib/routing/two_hop_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/two_hop.dart';
import 'package:fixture/routing/constant_page.dart';

final twoHopRoutes = [
  GoRoute(
    path: hopB.goRoute,
    builder: (context, state) => const ConstantPage(),
  ),
];
''');
  write('lib/routing/two_hop_caller.dart', '''
import 'package:fixture/routing/two_hop.dart';

class TwoHopCaller {
  void build(dynamic context) {
    context.go(hopB.path);
  }
}
''');

  // Beyond-cap (4-hop chain of constants referencing constants): resolving
  // `hop4` down to `AppPaths.` takes 4 substitutions, one more than the
  // depth-3 cap — must stay unresolved (never guess past the cap).
  write('lib/routing/four_hop.dart', '''
import 'package:fixture/routing/app_paths.dart';

final hop1 = AppPaths.constant;
final hop2 = hop1;
final hop3 = hop2;
final hop4 = hop3;
''');
  write('lib/routing/four_hop_caller.dart', '''
import 'package:fixture/routing/four_hop.dart';

class FourHopCaller {
  void build(dynamic context) {
    context.go(hop4.path);
  }
}
''');

  // --- Shadowing / reachability gate fixtures ------------------
  //
  // Local-parameter shadow: `shadowParamCaller` imports `constant_routes.dart`
  // (so `constantRoute` IS reachable) but its own method declares a
  // PARAMETER named `constantRoute` — a syntax-only pass can't tell this
  // `constantRoute.path` apart from the imported one, so it must refuse
  // rather than resolve through the distant (correctly-named but
  // shadowed) constant.
  write('lib/routing/shadow_param_caller.dart', '''
import 'package:fixture/routing/constant_routes.dart';

class ShadowParamCaller {
  void build(dynamic context, dynamic constantRoute) {
    context.go(constantRoute.path);
  }
}
''');

  // Local-variable shadow: same idea, but the shadow is a local variable
  // declared inside the method body instead of a parameter.
  write('lib/routing/shadow_local_caller.dart', '''
import 'package:fixture/routing/constant_routes.dart';

class ShadowLocalCaller {
  void build(dynamic context, dynamic something) {
    final constantRoute = something;
    context.go(constantRoute.path);
  }
}
''');

  // Unimported constant: `unreachableCaller` uses `constantRoute.path` but
  // does NOT import `constant_routes.dart` (or anything that transitively
  // imports/exports it) — the declaring file is not import-reachable, so
  // this must refuse even though the name matches and there is no shadow.
  write('lib/routing/unreachable_caller.dart', '''
class UnreachableCaller {
  void build(dynamic context) {
    context.go(constantRoute.path);
  }
}
''');

  // Same-file constant: a file that both DECLARES a route constant AND
  // consumes it directly — `declaredNames` obviously contains the name, but
  // the self-reference exception must still let it resolve (the shadowing guard must
  // not break the ordinary "declare and use in one file" shape).
  write('lib/routing/self_const_page.dart', '''
class SelfConstPage {
  const SelfConstPage();
}
''');
  write('lib/routing/self_const_caller.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/self_const_page.dart';

final selfConstRoute = AppPaths.selfConst;

final selfConstRoutes = [
  GoRoute(
    path: selfConstRoute.goRoute,
    builder: (context, state) => const SelfConstPage(),
  ),
];

class SelfConstCaller {
  void build(dynamic context) {
    context.go(selfConstRoute.path);
  }
}
''');

  // --- Cross-file constant identity fixtures -------------------
  //
  // Two same-name/same-TEXT constants declared in different files (distinct
  // AppPaths contexts) — a caller reachable from only ONE of them must still
  // resolve (identity is file-based now, not text-based); a caller reachable
  // from BOTH must refuse even though the text is identical, since file
  // identity — not initializer text — is what now disambiguates.
  write('lib/routing/same_text_const_a.dart', '''
import 'package:fixture/routing/app_paths.dart';

final sameTextRoute = AppPaths.constant;
''');
  write('lib/routing/same_text_const_b.dart', '''
import 'package:fixture/routing/app_paths.dart';

final sameTextRoute = AppPaths.constant;
''');
  // Reaches only A — must resolve.
  write('lib/routing/same_text_single_reach_caller.dart', '''
import 'package:fixture/routing/same_text_const_a.dart';

class SameTextSingleReachCaller {
  void build(dynamic context) {
    context.go(sameTextRoute.path);
  }
}
''');
  // Reaches BOTH A and B — must refuse (two distinct declaring files,
  // identical text, both reachable).
  write('lib/routing/same_text_both_reach_caller.dart', '''
import 'package:fixture/routing/same_text_const_a.dart';
import 'package:fixture/routing/same_text_const_b.dart';

class SameTextBothReachCaller {
  void build(dynamic context) {
    context.go(sameTextRoute.path);
  }
}
''');

  // --- Mechanism (b): monomorphic helper inlining fixtures ---------------
  //
  // Mirrors a common `GoRoute buildMenuSessionsRoute(Sessions
  // sessionsRoute) => GoRoute(path: sessionsRoute.goRoute, ...);` shape
  // (lib/sessions/sessions_routes.dart), called exactly once with
  // `buildMenuSessionsRoute(AppPaths.menu.sessions)`
  // (lib/core/router/home_routes.dart).
  write('lib/routing/helper_page.dart', '''
class HelperPage {
  const HelperPage();
}
''');
  write('lib/routing/single_site_helper.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute buildHelperRoute(dynamic route) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');
  write('lib/routing/single_site_helper_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/single_site_helper.dart';

final singleSiteRoutes = [
  buildHelperRoute(AppPaths.helper),
];

class SingleSiteHelperCaller {
  void build(dynamic context) {
    context.go(AppPaths.helper.path);
  }
}
''');

  // Second-call-site regression: the SAME helper function, but called from
  // two different places project-wide — the refusal gate must drop the
  // resolution even though the first call site alone would have resolved.
  write('lib/routing/two_site_helper.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute buildTwoSiteRoute(dynamic route) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');
  write('lib/routing/two_site_helper_caller_a.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/two_site_helper.dart';

final twoSiteRoutesA = [
  buildTwoSiteRoute(AppPaths.helper2),
];

class TwoSiteHelperCallerA {
  void build(dynamic context) {
    context.go(AppPaths.helper2.path);
  }
}
''');
  write('lib/routing/two_site_helper_caller_b.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/two_site_helper.dart';

final twoSiteRoutesB = [
  buildTwoSiteRoute(AppPaths.wrapped),
];
''');

  // Named-argument regression: the helper is called exactly once, but with a
  // NAMED argument instead of positional — the refusal gate must drop the
  // resolution (named/reordered params can never be matched positionally).
  write('lib/routing/named_arg_helper.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute buildNamedArgRoute({required dynamic route}) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');
  write('lib/routing/named_arg_helper_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/named_arg_helper.dart';

final namedArgRoutes = [
  buildNamedArgRoute(route: AppPaths.named),
];

class NamedArgHelperCaller {
  void build(dynamic context) {
    context.go(AppPaths.named.path);
  }
}
''');

  // --- Helper-declaration-identity + tear-off gate fixtures ----
  //
  // Two DIFFERENT top-level functions sharing the SAME name (in different
  // files) — one called, one never called. Gate (i) (exactly one
  // DECLARATION project-wide) must drop the name entirely: neither call
  // site's helper resolves, even the one with a legitimate single call site,
  // because the bare function name alone can no longer identify which
  // declaration it means.
  write('lib/routing/dup_helper_decl_a.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute dupNamedHelper(dynamic route) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');
  write('lib/routing/dup_helper_decl_a_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/dup_helper_decl_a.dart';

final dupHelperDeclARoutes = [
  dupNamedHelper(AppPaths.dupHelper),
];

class DupHelperDeclACaller {
  void build(dynamic context) {
    context.go(AppPaths.dupHelper.path);
  }
}
''');
  // Second declaration, same name, never called anywhere — its mere
  // existence must poison the name for `dup_helper_decl_a_caller.dart`'s
  // otherwise-single call site too.
  write('lib/routing/dup_helper_decl_b.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute dupNamedHelper(dynamic route) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');

  // Cross-file tear-off: a single-declaration, single-call-site helper that
  // WOULD resolve, except a third file references the bare function name
  // (a tear-off, e.g. assigned to a callback) — gate (iii) must refuse
  // because that reference could be a second, differently-shaped use this
  // syntax-only pass cannot see.
  write('lib/routing/tearoff_helper.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/helper_page.dart';

GoRoute buildTearoffRoute(dynamic route) {
  return GoRoute(
    path: route.goRoute,
    builder: (context, state) => const HelperPage(),
  );
}
''');
  write('lib/routing/tearoff_helper_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/tearoff_helper.dart';

final tearoffRoutes = [
  buildTearoffRoute(AppPaths.tearoff),
];

class TearoffHelperCaller {
  void build(dynamic context) {
    context.go(AppPaths.tearoff.path);
  }
}
''');
  write('lib/routing/tearoff_referencer.dart', '''
import 'package:fixture/routing/tearoff_helper.dart';

class TearoffReferencer {
  // A tear-off — not a call. Referenced from neither the declaring file nor
  // the single call-site file, so gate (iii) must see this and refuse.
  final callback = buildTearoffRoute;
}
''');

  // --- goNamed duplicate `name:` fixtures ----------------------
  //
  // Two GoRoutes in different files declaring the SAME `name:` — go_router
  // itself requires route names to be unique, so this is a project bug, but
  // the tool must never silently pick one (first-wins, the pre-0.5.0
  // behavior) — both must refuse to resolve via goNamed.
  write('lib/routing/dup_named_target_a.dart', '''
class DupNamedTargetA {
  const DupNamedTargetA();
}
''');
  write('lib/routing/dup_named_target_b.dart', '''
class DupNamedTargetB {
  const DupNamedTargetB();
}
''');
  write('lib/routing/dup_named_routes_a.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/dup_named_target_a.dart';

final dupNamedRoutesA = [
  GoRoute(
    path: '/dup-named-a',
    name: 'dup-named',
    builder: (context, state) => const DupNamedTargetA(),
  ),
];
''');
  write('lib/routing/dup_named_routes_b.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/dup_named_target_b.dart';

final dupNamedRoutesB = [
  GoRoute(
    path: '/dup-named-b',
    name: 'dup-named',
    builder: (context, state) => const DupNamedTargetB(),
  ),
];
''');
  write('lib/routing/dup_named_caller.dart', '''
class DupNamedCaller {
  void build(dynamic context) {
    context.goNamed('dup-named');
  }
}
''');

  // --- Mechanism (c): wrapper allowlist + goNamed fixtures ---------------
  //
  // Mirrors a common `pageBuilder: (_, state) => MaterialPage(child:
  // CardScannerPage(...))` shape
  // (lib/find_upn/routing/find_upn_routes.dart).
  write('lib/routing/material_page_target.dart', '''
class MaterialPageTarget {
  const MaterialPageTarget();
}
''');
  write('lib/routing/material_page_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/material_page_target.dart';

final materialPageRoutes = [
  GoRoute(
    path: AppPaths.materialWrap.goRoute,
    pageBuilder: (context, state) => MaterialPage(
      child: const MaterialPageTarget(),
    ),
  ),
];
''');
  write('lib/routing/material_page_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class MaterialPageCaller {
  void build(dynamic context) {
    context.go(AppPaths.materialWrap.path);
  }
}
''');

  // Wrapper-in-wrapper: two allowlisted types nested (MaterialPage wrapping
  // a CustomTransitionPage wrapping the real page) — both unwrap, resolving
  // to the innermost page.
  write('lib/routing/nested_wrapper_target.dart', '''
class NestedWrapperTarget {
  const NestedWrapperTarget();
}
''');
  write('lib/routing/nested_wrapper_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/app_paths.dart';
import 'package:fixture/routing/nested_wrapper_target.dart';

final nestedWrapperRoutes = [
  GoRoute(
    path: AppPaths.nestedWrap.goRoute,
    pageBuilder: (context, state) => MaterialPage(
      child: CustomTransitionPage(
        child: const NestedWrapperTarget(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            child,
      ),
    ),
  ),
];
''');
  write('lib/routing/nested_wrapper_caller.dart', '''
import 'package:fixture/routing/app_paths.dart';

class NestedWrapperCaller {
  void build(dynamic context) {
    context.go(AppPaths.nestedWrap.path);
  }
}
''');

  // goNamed <-> name: exact-string match fixture — a GoRoute declares
  // `name: 'lit'`, a caller navigates via `context.goNamed('lit')`.
  write('lib/routing/go_named_target.dart', '''
class GoNamedTarget {
  const GoNamedTarget();
}
''');
  write('lib/routing/go_named_routes.dart', '''
import 'package:go_router/go_router.dart';
import 'package:fixture/routing/go_named_target.dart';

final goNamedRoutes = [
  GoRoute(
    path: '/lit',
    name: 'lit',
    builder: (context, state) => const GoNamedTarget(),
  ),
];
''');
  write('lib/routing/go_named_caller.dart', '''
class GoNamedCaller {
  void build(dynamic context) {
    context.goNamed('lit');
  }
}
''');

  // --- 0.8.0 Stage B: blueprint fixtures --------------------------------
  //
  // A small LAYERED feature (domain → data → application → presentation →
  // routing) with an INTERNAL provider dep (controller watches the repository
  // provider, both in-feature) and an EXTERNAL one (controller watches a
  // dedicated cross-area provider in its own area, so it never perturbs the
  // shared home/budget reader-count assertions elsewhere in this suite).
  write(
    'lib/sampleext/sample_ext_provider.dart',
    "final sampleExtProvider = "
        "Provider<int>((ref) => 1, name: 'sampleExtProvider');\n"
        // A cross-area provider read ONLY by the sample PAGE (a non-provider
        // file), via a field-held `_ref` — exercises both the field-Ref
        // receiver detection and the comprehensive external-seam (a page's
        // cross-area read must surface in the seam, not just providers' deps).
        "final sampleExtPageProvider = "
        "Provider<int>((ref) => 2, name: 'sampleExtPageProvider');\n",
  );
  write(
    'lib/features/sample/domain/sample_failure.dart',
    'class SampleFailure {}\n',
  );
  write(
    'lib/features/sample/data/sample_repository.dart',
    'class SampleRepository {}\n',
  );
  // Files are wired into an intra-feature import chain (as a real feature is)
  // so they don't register as "files nothing imports" orphans — that keeps the
  // shared home_zzz_orphan.dart ATTENTION anchor stable.
  // This ONE file declares TWO providers (repository + cookie-jar), mirroring
  // a typical repository-provider pattern. Only the repository
  // provider watches an external provider (sampleExtProvider); the cookie-jar
  // provider watches nothing. Because watch/read/listen edges are file-granular,
  // blueprint MUST NOT attribute the external dep to the non-watching sibling.
  write('lib/features/sample/data/sample_repository_provider.dart', '''
import 'package:fixture/features/sample/data/sample_repository.dart';
import 'package:fixture/sampleext/sample_ext_provider.dart';

final sampleCookieJarProvider =
    Provider<int>((ref) => 0, name: 'sampleCookieJarProvider');

final sampleRepositoryProvider = Provider<SampleRepository>((ref) {
  ref.watch(sampleExtProvider);
  return SampleRepository();
}, name: 'sampleRepositoryProvider');
''');
  write('lib/features/sample/application/sample_service.dart', '''
import 'package:fixture/features/sample/domain/sample_failure.dart';

class SampleService {
  SampleFailure? lastFailure;
}
''');
  write(
      'lib/features/sample/presentation/controller/sample_controller.dart', '''
import 'package:fixture/features/sample/application/sample_service.dart';
import 'package:fixture/features/sample/data/sample_repository_provider.dart';
import 'package:fixture/sampleext/sample_ext_provider.dart';

final sampleControllerProvider = Provider<SampleService>((ref) {
  ref.watch(sampleRepositoryProvider);
  ref.watch(sampleExtProvider);
  return SampleService();
}, name: 'sampleControllerProvider');
''');
  write('lib/features/sample/presentation/sample_page.dart', '''
import 'package:fixture/features/sample/presentation/controller/sample_controller.dart';
import 'package:fixture/features/sample/presentation/widget/sample_button.dart';
import 'package:fixture/sampleext/sample_ext_provider.dart';

class SamplePage {
  final dynamic _ref;
  SamplePage(this._ref);
  void render() {
    sampleControllerProvider;
    // Field-held Ref (not a local `ref`) reading a cross-area provider — must
    // still produce a read edge (field-Ref receiver detection).
    _ref.read(sampleExtPageProvider);
    SampleButton();
  }
}
''');
  write('lib/features/sample/routing/sample_routes.dart', '''
import 'package:fixture/features/sample/presentation/sample_page.dart';

class SampleRoutes {
  SamplePage build() => SamplePage();
}
''');
  write('lib/features/sample/presentation/widget/sample_button.dart', '''
class SampleButton {}
''');
  // A test file referencing sampleControllerProvider — credits its declaring
  // file with a testRef so the blueprint TESTS line is non-zero.
  write('test/sample_controller_test.dart', '''
import 'package:fixture/features/sample/presentation/controller/sample_controller.dart';

void main() {
  sampleControllerProvider;
}
''');

  // A FLAT feature (files directly under the prefix, no layer dirs) — exercises
  // blueprint's role-fallback grouping. Chained page → controller → repository
  // so only the top page is an orphan (kept minimal to preserve the shared
  // ATTENTION orphan-section anchor).
  write(
    'lib/features/flat/flat_repository.dart',
    'class FlatRepository {}\n',
  );
  write('lib/features/flat/flat_controller.dart', '''
import 'package:fixture/features/flat/flat_repository.dart';

class FlatController {
  final FlatRepository repo = FlatRepository();
}
''');
  write('lib/features/flat/flat_page.dart', '''
import 'package:fixture/features/flat/flat_controller.dart';

class FlatPage {
  final FlatController controller = FlatController();
}
''');
  // A routing file imports the page so the page isn't a "files nothing imports"
  // orphan (keeps the shared ATTENTION anchor stable); `_routes.dart` is itself
  // excluded from orphan detection by the engine's entrypoint rule.
  write('lib/features/flat/flat_routes.dart', '''
import 'package:fixture/features/flat/flat_page.dart';

class FlatRoutes {
  FlatPage build() => FlatPage();
}
''');
}
