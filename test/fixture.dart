import 'dart:io';

/// A small Flutter-shaped repository: an app package with Riverpod-style
/// providers, two path packages (one publishable), tests, a tool script, and
/// an excluded vendor directory. Riverpod itself is a minimal stand-in under
/// `.deps/` so the fixture resolves without pub.
Directory writeFixture() {
  final root = Directory.systemTemp.createTempSync('codegraph_fixture_');
  final path = root.resolveSymbolicLinksSync();
  void write(String rel, String content) {
    File('$path/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  write('pubspec.yaml', '''
name: app
publish_to: none
environment:
  sdk: ^3.9.0
''');
  write('analysis_options.yaml', '''
analyzer:
  exclude:
    - vendor/**
''');
  write('packages/app_ui/pubspec.yaml', '''
name: app_ui
publish_to: none
environment:
  sdk: ^3.9.0
''');
  write('packages/shared_kit/pubspec.yaml', '''
name: shared_kit
environment:
  sdk: ^3.9.0
''');
  write('.deps/riverpod/lib/riverpod.dart', '''
class Ref {
  T watch<T>(ProviderBase<T> provider) => throw '';
  T read<T>(ProviderBase<T> provider) => throw '';
  void listen<T>(ProviderBase<T> provider, void Function(T? a, T b) f) {}
  void invalidate(ProviderBase<Object?> provider) {}
}

abstract class ProviderBase<T> {
  ProviderBase<T> overrideWith(Object create) => this;
}

class Provider<T> extends ProviderBase<T> {
  Provider(T Function(Ref ref) create);

  static ProviderFamily<T, A> family<T, A>(T Function(Ref ref, A arg) create) =>
      ProviderFamily<T, A>(create);
}

class ProviderFamily<T, A> {
  ProviderFamily(T Function(Ref ref, A arg) create);
  Provider<T> call(A arg) => throw '';
}

abstract class Notifier<T> {
  T build();
}
''');
  write('.deps/riverpod_annotation/lib/riverpod_annotation.dart', '''
export 'package:riverpod/riverpod.dart' show Ref;

const riverpod = Riverpod();

class Riverpod {
  const Riverpod();
}
''');
  write('.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name": "app", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.9"},
    {"name": "app_ui", "rootUri": "../packages/app_ui", "packageUri": "lib/", "languageVersion": "3.9"},
    {"name": "shared_kit", "rootUri": "../packages/shared_kit", "packageUri": "lib/", "languageVersion": "3.9"},
    {"name": "riverpod", "rootUri": "../.deps/riverpod", "packageUri": "lib/", "languageVersion": "3.9"},
    {"name": "riverpod_annotation", "rootUri": "../.deps/riverpod_annotation", "packageUri": "lib/", "languageVersion": "3.9"}
  ]
}
''');

  write('packages/app_ui/lib/button.dart', '''
/// A tappable label.
class AppButton {
  const AppButton(this.label);
  final String label;
}
''');
  write('packages/shared_kit/lib/shared_kit.dart', '''
class Kit {
  const Kit();
  String describe() => 'kit';
}
''');

  write('lib/core/keys.dart', '''
/// A dotted key a remote document can name.
abstract interface class FeatureKey {
  String get key;
}

enum Gate implements FeatureKey {
  household('household'),
  payment('payment');

  const Gate(this.key);

  @override
  final String key;
}

String walletKey(String id) => 'wallet.\$id';

bool keyIsUnder(String key, String root) => key.startsWith(root);

mixin Loud {
  String shout(String s) => s.toUpperCase();
}

class Announcer with Loud {}

enum Tone { soft, loud }
''');
  write('lib/core/backend.dart', '''
import 'package:app/core/keys.dart';

enum Backend implements FeatureKey {
  billing;

  @override
  String get key => 'backend.\$name';
}
''');
  write('lib/core/session.dart', '''
import 'package:riverpod/riverpod.dart';

class Session {
  Session(this.token);
  final String token;
}

final sessionProvider = Provider<Session>((ref) => Session('t'));

final flagProvider = Provider.family<bool, String>((ref, key) => true);

/// Holds a ref so feature code can read providers later.
class Deps {
  Deps(this.ref);
  final Ref ref;
}
''');
  write('lib/core/store.dart', '''
abstract class Store {
  void save(String value);
}

class DiskStore implements Store {
  @override
  void save(String value) {}
}

class Buffer {
  void flush() {}
}

void poke(dynamic target) => target.flush();
''');
  write('lib/core/greeting.dart', '''
import 'package:riverpod_annotation/riverpod_annotation.dart';

@riverpod
String greeting(Ref ref) => 'hello';
''');
  write('lib/features/home/home_page.dart', '''
import 'package:app/core/keys.dart';
import 'package:app/core/session.dart';
import 'package:app_ui/button.dart';
import 'package:riverpod/riverpod.dart';
import 'package:shared_kit/shared_kit.dart';

class HomePage {
  String build(Ref ref) {
    final session = ref.watch(sessionProvider);
    ref.listen(sessionProvider, (a, b) {});
    const button = AppButton('go');
    const kit = Kit();
    return '\${session.token}\${button.label}\${kit.describe()}\${walletKey('x')}';
  }

  void signOut(Deps deps) {
    deps.ref.read(sessionProvider);
    deps.ref.invalidate(sessionProvider);
  }
}

bool householdOpen(Ref ref) => ref.watch(flagProvider(Gate.household.key));
''');
  write('lib/features/home/details_view.dart', '''
class DetailsView {
  const DetailsView({required this.loading, required this.title});
  final bool loading;
  final String title;
}

DetailsView resolveDetailsView({required bool loading, required String title}) {
  return DetailsView(loading: loading, title: title);
}
''');
  write('lib/features/home/details_controller.dart', '''
import 'package:app/core/keys.dart';
import 'package:app/features/home/details_view.dart';

DetailsView currentView() => resolveDetailsView(loading: true, title: 'x');

Tone pickTone() => Tone.soft;
''');
  write('lib/features/labels.dart', '''
class Base {
  Base({required this.label});
  final String label;
}

class Child extends Base {
  Child({required super.label});
}

Child makeChild() => Child(label: 'c');
Base makeBase() => Base(label: 'b');

class Wallets {
  static const sandbox = ['a', 'b'];
}

const policyNote = 'sandbox wallets live in Wallets.sandbox';
''');
  write('lib/features/wallet_list.dart', '''
import 'package:app/features/labels.dart';

int walletCount() => Wallets.sandbox.length;
''');
  write('tool/shots.dart', '''
import 'package:app/features/labels.dart';

void main() => print(Wallets.sandbox);
''');
  write('vendor/legacy.dart', '''
import 'package:app/core/session.dart';

final legacy = sessionProvider;
''');
  write('test/home_test.dart', '''
import 'package:app/core/session.dart';
import 'package:app/core/store.dart';
import 'package:app/features/labels.dart';
import 'package:riverpod/riverpod.dart';

class FakeStore extends Store {
  @override
  void save(String value) {}
}

void main() {
  Ref? ref;
  ref?.read(sessionProvider);
  sessionProvider.overrideWith((Ref r) => Session('fake'));
  print(Wallets.sandbox);
  FakeStore().save('x');
}
''');
  return Directory(path);
}

/// Runs git in [root], failing loudly.
void git(Directory root, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: root.path);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
}

void initGit(Directory root) {
  git(root, ['init', '-q']);
  git(root, ['add', '-A']);
  git(root, [
    '-c',
    'user.email=t@t',
    '-c',
    'user.name=t',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '-qm',
    'fixture',
    '--no-verify',
  ]);
}
