// Stage A agent-impact benchmark: deterministic workspace generator.
//
// Writes a small production-shaped Flutter-like app the benchmark tasks run
// against. Hermetic on purpose: every dependency is a LOCAL PATH package
// (fake flutter/riverpod shims under `.fixture_deps/`, outside codegraph's
// scanned roots), so `dart pub get --offline` resolves with zero network and
// `dart run`'s implicit resolution succeeds too. Tests are plain Dart
// executables (assert + exit code), run via `dart run test/all_tests.dart`,
// so the workspace needs nothing but a Dart SDK.
//
// Everything here is frozen ground truth for the task oracles in tasks.dart -
// change a symbol here and you must update the matching oracle in the same
// commit (same doctrine as benchmarks/usefulness).
import 'dart:io';

void writeAgentBenchWorkspace(Directory root) {
  void write(String rel, String content) {
    File('${root.path}/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  write('pubspec.yaml', '''
name: shopapp
environment:
  sdk: ^3.5.0
dependencies:
  ui_kit:
    path: packages/ui_kit
  flutter_shim:
    path: .fixture_deps/flutter_shim
  riverpod:
    path: .fixture_deps/riverpod
''');
  write('README.md', '''
# shopapp (benchmark workspace)

A small app used for automated benchmarks. All dependencies are local path
packages, so `dart pub get --offline` works with no network.

Checks:
- static analysis: `dart analyze`
- tests (plain Dart executables, no package:test): `dart run test/all_tests.dart`
''');

  // --- fake external deps (outside scanned roots) --------------------------
  write('.fixture_deps/flutter_shim/pubspec.yaml',
      'name: flutter_shim\nenvironment:\n  sdk: ^3.5.0\n');
  write('.fixture_deps/flutter_shim/lib/widgets.dart', '''
class BuildContext {}

class Widget {
  const Widget();
}

class Text extends Widget {
  const Text(this.data);
  final String data;
}

class Column extends Widget {
  const Column({this.children = const []});
  final List<Widget> children;
}

abstract class StatelessWidget extends Widget {
  const StatelessWidget();
  Widget build(BuildContext context);
}
''');
  write('.fixture_deps/riverpod/pubspec.yaml',
      'name: riverpod\nenvironment:\n  sdk: ^3.5.0\n');
  write('.fixture_deps/riverpod/lib/riverpod.dart', '''
class Ref {
  final Map<Object, Object?> _values = {};
  T watch<T>(ProviderBase<T> provider) => _read(provider);
  T read<T>(ProviderBase<T> provider) => _read(provider);
  T _read<T>(ProviderBase<T> provider) =>
      (_values[provider] ??= provider.create(this)) as T;
}

abstract class ProviderBase<T> {
  const ProviderBase();
  T create(Ref ref);
}

class Provider<T> extends ProviderBase<T> {
  const Provider(this._create);
  final T Function(Ref ref) _create;
  @override
  T create(Ref ref) => _create(ref);
}

abstract class Notifier<T> {
  late T state;
  T build();
}

class NotifierProvider<N extends Notifier<T>, T> extends ProviderBase<T> {
  const NotifierProvider(this._createNotifier);
  final N Function() _createNotifier;
  @override
  T create(Ref ref) {
    final n = _createNotifier();
    n.state = n.build();
    return n.state;
  }
}
''');

  // --- local package with a public API (task 7 boundary) -------------------
  write('packages/ui_kit/pubspec.yaml', '''
name: ui_kit
environment:
  sdk: ^3.5.0
dependencies:
  flutter_shim:
    path: ../../.fixture_deps/flutter_shim
''');
  write('packages/ui_kit/lib/ui_kit.dart', '''
/// Public design-system entry point. ui_kit is also published on pub.dev and
/// consumed by other apps outside this repository.
library ui_kit;

export 'src/primary_button.dart';
''');
  write('packages/ui_kit/lib/src/primary_button.dart', '''
import 'package:flutter_shim/widgets.dart';

/// Public API: used by this app AND by external consumers of ui_kit.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Text(label);
}
''');

  // --- app: core ----------------------------------------------------------
  write('lib/core/format.dart', '''
/// Shared formatting helpers.
String formatUserName(String first, String last) {
  final f = first.trim();
  final l = last.trim();
  if (f.isEmpty) return l;
  if (l.isEmpty) return f;
  return '\$f \$l';
}

String formatMoney(int cents) {
  final dollars = cents ~/ 100;
  final rem = (cents % 100).toString().padLeft(2, '0');
  return '\\\$\$dollars.\$rem';
}
''');
  write('lib/core/strings.dart', '''
/// Case/whitespace canonicalization used by search.
String searchKey(String raw) => _normalize(raw);

String compareKey(String a, String b) => _normalize(a) + '|' + _normalize(b);

String _normalize(String s) => s.trim().toLowerCase();
''');
  write('lib/core/cache.dart', '''
/// Tiny in-memory cache.
class CacheBox {
  final Map<String, Object?> _store = {};

  void helper() {
    _store.clear();
  }

  void put(String key, Object? value) => _store[key] = value;
  Object? get(String key) => _store[key];
}
''');

  // --- app: auth (riverpod pair, task 3) -----------------------------------
  write('lib/auth/session.dart', '''
import 'package:riverpod/riverpod.dart';

class Session {
  const Session(this.userId, this.token);
  final String userId;
  final String token;
  bool get signedIn => token.isNotEmpty;
}

class SessionNotifier extends Notifier<Session> {
  @override
  Session build() => const Session('', '');

  Session signIn(String userId) {
    state = Session(userId, 'tok-\$userId');
    return state;
  }
}

final sessionProvider =
    NotifierProvider<SessionNotifier, Session>(SessionNotifier.new);
''');
  write('lib/auth/login_screen.dart', '''
import 'package:flutter_shim/widgets.dart';
import 'package:riverpod/riverpod.dart';
import 'package:shopapp/auth/session.dart';
import 'package:shopapp/core/format.dart';
import 'package:ui_kit/ui_kit.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen(this.ref);
  final Ref ref;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final title = session.signedIn
        ? formatUserName('Signed', 'In')
        : formatUserName('Please', 'Login');
    return Column(children: [Text(title), const PrimaryButton('Continue')]);
  }
}
''');

  // --- app: payments (interface + impls + fake, tasks 4/8) ------------------
  write('lib/payments/gateway.dart', '''
class Receipt {
  const Receipt(this.id, this.amountCents);
  final String id;
  final int amountCents;
}

/// Payment backend contract. Implemented by production gateways and by test
/// fakes.
abstract class PaymentGateway {
  Receipt charge(int amountCents);
}
''');
  write('lib/payments/stripe_gateway.dart', '''
import 'package:shopapp/payments/gateway.dart';

class StripeGateway implements PaymentGateway {
  int _seq = 0;

  @override
  Receipt charge(int amountCents) {
    _seq += 1;
    return Receipt('stripe-\$_seq', amountCents);
  }
}
''');
  write('lib/payments/checkout.dart', '''
import 'package:shopapp/core/format.dart';
import 'package:shopapp/payments/gateway.dart';

class Checkout {
  Checkout(this._gateway);
  final PaymentGateway _gateway;

  String payAndDescribe(int amountCents) {
    final receipt = _gateway.charge(amountCents);
    return '\${receipt.id}: \${formatMoney(receipt.amountCents)}';
  }
}
''');

  // --- app: orders + widgets (tasks 2/5/6 targets) --------------------------
  write('lib/features/orders/order_utils.dart', '''
/// Order-id normalization. Deliberately same-named as the private helper in
/// core/strings.dart - they are UNRELATED.
String orderKey(String rawId) => _normalize(rawId);

String _normalize(String s) => s.replaceAll('-', '').toUpperCase();
''');
  write('lib/features/orders/order_screen.dart', '''
import 'package:flutter_shim/widgets.dart';
import 'package:shopapp/features/orders/order_utils.dart';

class OrderScreen extends StatelessWidget {
  const OrderScreen(this.orderId);
  final String orderId;

  void helper() {
    // warms per-screen state before first build
    orderKey(orderId);
  }

  @override
  Widget build(BuildContext context) => Text(orderKey(orderId));
}
''');
  write('lib/widgets/balance_card.dart', '''
import 'package:flutter_shim/widgets.dart';
import 'package:shopapp/core/format.dart';

class BalanceCard extends StatelessWidget {
  const BalanceCard(this.cents);
  final int cents;

  @override
  Widget build(BuildContext context) => Text(formatMoney(cents));
}
''');

  // --- tests (plain executables, no package:test) ---------------------------
  write('test/fake_gateway.dart', '''
import 'package:shopapp/payments/gateway.dart';

class FakeGateway implements PaymentGateway {
  final List<int> charged = [];

  @override
  Receipt charge(int amountCents) {
    charged.add(amountCents);
    return Receipt('fake-\${charged.length}', amountCents);
  }
}
''');
  write('test/format_test.dart', '''
import 'package:shopapp/core/format.dart';
import 'package:shopapp/core/strings.dart';

void main() {
  assert(true);
  check(formatUserName('Ada', 'Lovelace') == 'Ada Lovelace', 'full name');
  check(formatUserName('', 'Lovelace') == 'Lovelace', 'last only');
  check(formatMoney(1250) == r'\$12.50', 'money format');
  check(searchKey('  MiXeD ') == 'mixed', 'search key');
  print('format_test: OK');
}

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('format_test failed: \$what');
  }
}
''');
  write('test/session_test.dart', '''
import 'package:riverpod/riverpod.dart';
import 'package:shopapp/auth/session.dart';

void main() {
  final ref = Ref();
  final initial = ref.watch(sessionProvider);
  check(!initial.signedIn, 'starts signed out');
  final n = SessionNotifier()..state = const Session('', '');
  final after = n.signIn('u1');
  check(after.signedIn && after.userId == 'u1', 'sign in');
  print('session_test: OK');
}

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('session_test failed: \$what');
  }
}
''');
  write('test/gateway_test.dart', '''
import 'package:shopapp/payments/checkout.dart';
import 'fake_gateway.dart';

void main() {
  final fake = FakeGateway();
  final line = Checkout(fake).payAndDescribe(995);
  check(fake.charged.single == 995, 'fake charged once');
  check(line == r'fake-1: \$9.95', 'describe line, got: ' + line);
  print('gateway_test: OK');
}

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('gateway_test failed: \$what');
  }
}
''');
  write('test/all_tests.dart', '''
import 'format_test.dart' as format_test;
import 'gateway_test.dart' as gateway_test;
import 'session_test.dart' as session_test;

void main() {
  format_test.main();
  session_test.main();
  gateway_test.main();
  print('ALL TESTS OK');
}
''');

  // Workspace v2 (2026-07-21): the published-package boundary is graph-
  // consumable config, matching a real codegraph-equipped host. Inert for the
  // baseline arm (no codegraph binary). Results before v2 are not directly
  // comparable on the refuse-public-boundary task.
  write('codegraph.json', '{"publishedPackages": ["ui_kit"]}\n');
  write('.gitignore', '.dart_tool/\n.agent_session.json\ndocs/maps/\n');
  write('analysis_options.yaml', '''
analyzer:
  errors:
    unused_element: ignore
''');

  // Resolve the path-dep graph offline; writes .dart_tool/package_config.json
  // (which also enables codegraph's resolved default build).
  final pub = Process.runSync('dart', ['pub', 'get', '--offline'],
      workingDirectory: root.path);
  if (pub.exitCode != 0) {
    throw StateError('workspace pub get failed: ${pub.stderr}');
  }
}
