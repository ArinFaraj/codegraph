import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/refs.dart';
import 'package:codegraph/src/result.dart';
import 'package:codegraph/src/show.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Analysis analysis;
  late Engine engine;

  setUpAll(() async {
    root = writeFixture();
    void write(String rel, String content) {
      File('${root.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    write('slang.yaml', '''
input_directory: lib/i18n/yaml
input_file_pattern: .yaml
output_directory: lib/i18n
base_locale: 1
key_case: camel
translation_overrides: true
''');
    write('lib/i18n/yaml/en.yaml', r'''
home:
  title: Home
  greet: Hi ${name}
  unused: Never shown
  sign_out: Sign out
''');
    write('lib/i18n/yaml/ar.yaml', r'''
home:
  title: الرئيسية
  greet: مرحبا ${name}
''');
    write('lib/i18n/strings.g.dart', '''
export 'strings_en.g.dart';
''');
    write('lib/i18n/strings_en.g.dart', r'''
class TranslationOverrides {
  static String? string(Object meta, String key, Map<String, Object> args) =>
      null;
}

final t = Translations();

class Translations {
  final Object $meta = Object();
  late final Translations _root = this;
  late final TranslationsHomeEn home = TranslationsHomeEn(_root);
}

class TranslationsHomeEn {
  TranslationsHomeEn(this._root);

  final Translations _root;

  String get title =>
      TranslationOverrides.string(_root.$meta, 'home.title', {}) ?? 'Home';
  String greet({required Object name}) =>
      TranslationOverrides.string(_root.$meta, 'home.greet', {'name': name}) ??
      'Hi $name';
  String get unused =>
      TranslationOverrides.string(_root.$meta, 'home.unused', {}) ??
      'Never shown';
  String get signOut =>
      TranslationOverrides.string(_root.$meta, 'home.signOut', {}) ??
      'Sign out';
}
''');
    write('lib/features/home/home_title.dart', '''
import 'package:app/i18n/strings.g.dart';

String homeTitle() => t.home.title;

String welcome(String name) => t.home.greet(name: name);
''');
    initGit(root);
    final ws = Workspace.find(root.path)!;
    analysis = await Analysis.open(ws, byteStore: '${root.path}.store');
    await analysis.warmUp();
    engine = Engine(analysis);
  });

  tearDownAll(() async {
    await analysis.dispose();
    root.deleteSync(recursive: true);
    Directory('${root.path}.store').deleteSync(recursive: true);
  });

  String text(Answer a) => a.render(asJson: false, limit: null);

  test('refs of a dotted key lists each locale line and the Dart uses', () async {
    final a = await refs(engine, 'home.title');
    expect(a.exit, Exit.ok);
    final out = text(a);
    expect(out, startsWith('translation key home.title\n'));
    expect(out, contains('  en   lib/i18n/yaml/en.yaml:2  Home'));
    expect(out, contains('  ar   lib/i18n/yaml/ar.yaml:2'));
    expect(out, contains('refs TranslationsHomeEn.title'));
    expect(
      out,
      contains(
        'lib/features/home/home_title.dart:3  String homeTitle() => t.home.title;',
      ),
    );
  });

  test('a Dart access path names the same key', () async {
    final out = text(await refs(engine, 't.home.greet'));
    expect(out, startsWith('translation key home.greet\n'));
    expect(out, contains('lib/features/home/home_title.dart:5'));
  });

  test('a key missing from a locale is flagged', () async {
    final out = text(await refs(engine, 'home.unused'));
    expect(out, startsWith('translation key home.unused, missing in ar\n'));
    expect(out, contains('  ar   missing from lib/i18n/yaml/ar.yaml'));
    expect(out, contains('no uses in'));
  });

  test('refs -C and show work on the key as on any getter', () async {
    final withContext = text(await refs(engine, 'home.title', context: 1));
    expect(withContext, contains('> 3  String homeTitle() => t.home.title;'));
    final shown = text(await showSymbol(engine, 'home.greet'));
    expect(shown, startsWith('translation key home.greet\n'));
    expect(shown, contains("'home.greet'"));
  });

  test('JSON carries the key, the locales and the uses', () async {
    final a = await refs(engine, 'home.unused');
    final j = jsonDecode(a.render(asJson: true, limit: null)) as Map;
    expect(j['key'], 'home.unused');
    expect((j['locales'] as List).map((l) => (l as Map)['line']), [4, null]);
    expect(j['uses'], isEmpty);
  });

  test('a name that is neither a declaration nor a key still fails', () async {
    final a = await refs(engine, 'home.nothing');
    expect(a.exit, Exit.failed);
    expect(text(a), isNot(contains('translation key')));
  });

  test('a key slang camel-cased is found under its YAML spelling', () async {
    final out = text(await refs(engine, 'home.signOut'));
    expect(out, startsWith('translation key home.signOut, missing in ar\n'));
    expect(out, contains('  en   lib/i18n/yaml/en.yaml:5  Sign out'));
  });

  test('slang added after the first query is picked up', () async {
    final slang = File('${root.path}/slang.yaml');
    final kept = slang.readAsStringSync();
    slang.deleteSync();
    expect((await refs(engine, 'home.title')).exit, Exit.failed);
    slang.writeAsStringSync(kept);
    final out = text(await refs(engine, 'home.title'));
    expect(out, startsWith('translation key home.title\n'));
  });
}
