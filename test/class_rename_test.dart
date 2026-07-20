// Class renames in the actuator (benchmark-mined: both Stage A failures traced
// to the actuator not covering the most common rename shape, so agents edited
// by hand around every safety net). Covers: every reference form of a class
// (constructors incl. named, static access, tear-offs, annotations, is-checks,
// type arguments) renames together and compiles; ambiguity refuses;
// the published-package boundary now fires on the exact campaign shape (a
// public class in a published package); the indexed path falls through to the
// cold analyzer path for non-executable targets instead of wrongly refusing.
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
    tempDir = Directory.systemTemp.createTempSync('codegraph_clsren_');
    writeCodegraphFixture(tempDir);
    writeFixturePackageConfig(tempDir);
    File('${tempDir.path}/lib/money.dart').writeAsStringSync('''
class Money {
  Money(this.cents);
  Money.zero() : cents = 0;
  final int cents;
  static Money parse(String s) => Money(int.parse(s));
}
''');
    File('${tempDir.path}/lib/wallet.dart').writeAsStringSync('''
import 'package:fixture/money.dart';

class Wallet {
  Money total = Money.zero();
  final List<Money> history = [];
  final Money Function(String) parser = Money.parse;
  Money addAll(List<Object> items) {
    for (final m in items) {
      if (m is Money) {
        total = Money(total.cents + m.cents);
        history.add(m);
      }
    }
    final make = Money.new;
    return make(total.cents);
  }
}
''');
    Directory.current = tempDir;
    engine.build(const []);
  });

  tearDown(() {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  test('class rename covers every reference form and stays resolvable',
      () async {
    final code = await rename.run(['rename', 'Money', 'Cash', '--apply']);
    expect(code, 0);
    final money = File('${tempDir.path}/lib/money.dart').readAsStringSync();
    final wallet = File('${tempDir.path}/lib/wallet.dart').readAsStringSync();
    for (final text in [money, wallet]) {
      expect(RegExp(r'\bMoney\b').hasMatch(text), isFalse,
          reason: 'no reference form may survive:\n$text');
    }
    expect(money, contains('class Cash {'));
    expect(money, contains('Cash.zero()'));
    expect(money, contains('static Cash parse'));
    expect(wallet, contains('Cash total = Cash.zero();'));
    expect(wallet, contains('List<Cash> history'));
    expect(wallet, contains('Cash.parse'));
    expect(wallet, contains('is Cash'));
    expect(wallet, contains('Cash.new'));
    // The renamed workspace must still fully resolve (analysis green).
    final analyze = Process.runSync(
        'dart', ['analyze', 'lib/money.dart', 'lib/wallet.dart']);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}${analyze.stderr}');
  });

  test('two unrelated same-named classes refuse as ambiguous', () async {
    File('${tempDir.path}/lib/other_money.dart').writeAsStringSync('''
class Money {
  const Money();
}
''');
    engine.build(const []);
    final code = await rename.run(['rename', 'Money', 'Cash']);
    expect(code, 3);
  });

  test(
      'published-package public class refuses - the exact Stage A campaign '
      'failure shape', () async {
    File('${tempDir.path}/codegraph.json')
        .writeAsStringSync('{"publishedPackages": ["fixture_ui"]}');
    final before =
        File('${tempDir.path}/packages/fixture_ui/lib/fancy_button.dart')
            .readAsStringSync();
    final code =
        await rename.run(['rename', 'FancyButton', 'BrandButton', '--apply']);
    expect(code, 3, reason: 'a published package\'s public class must refuse');
    expect(
        File('${tempDir.path}/packages/fixture_ui/lib/fancy_button.dart')
            .readAsStringSync(),
        before);
  });

  test('a fresh refactor index falls through to the cold path for classes',
      () async {
    await engine.buildResolved(const []); // writes refactor_index.json
    final code = await rename.run(['rename', 'Money', 'Cash']);
    expect(code, 0,
        reason: 'the executable index lacks classes; the indexed path must '
            'fall through, not refuse');
  });

  group(
      'file-scoped targeting (benchmark-mined: two files may declare the '
      'same private top-level helper)', () {
    setUp(() {
      File('${tempDir.path}/lib/strings_util.dart').writeAsStringSync('''
String searchKey(String raw) => _normalize(raw);
String _normalize(String s) => s.trim().toLowerCase();
''');
      File('${tempDir.path}/lib/order_util.dart').writeAsStringSync('''
String orderKey(String raw) => _normalize(raw);
String _normalize(String s) => s.replaceAll('-', '').toUpperCase();
''');
      engine.build(const []);
    });

    test('bare name refuses and suggests the file spelling', () async {
      final code = await rename.run(['rename', '_normalize', '_canonical']);
      expect(code, 3);
    });

    test('file.dart:name renames only that file, cold path', () async {
      final code = await rename.run([
        'rename',
        'lib/strings_util.dart:_normalize',
        '_canonical',
        '--apply'
      ]);
      expect(code, 0);
      final scoped =
          File('${tempDir.path}/lib/strings_util.dart').readAsStringSync();
      final other =
          File('${tempDir.path}/lib/order_util.dart').readAsStringSync();
      expect(scoped, isNot(contains('_normalize')));
      expect(scoped, contains('_canonical('));
      expect(other, contains('_normalize('),
          reason: 'the unrelated same-named helper must be untouched');
    });

    test('file.dart:name works through the refactor index too', () async {
      await engine.buildResolved(const []);
      final code = await rename
          .run(['rename', 'lib/strings_util.dart:_normalize', '_canonical']);
      expect(code, 0, reason: 'indexed path must honor the file scope');
    });
  });
}
