import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/query.dart' as query;
import 'package:test/test.dart';

import 'fixture.dart';

class _TestStderr implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding _) {}

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

void main() {
  late Directory tempDir;
  late Directory originalCwd;

  setUp(() {
    originalCwd = Directory.current;
    tempDir = Directory.systemTemp.createTempSync('codegraph_unknown_verb_');
    writeCodegraphFixture(tempDir);
    Directory.current = tempDir;
    engine.build(const []);
  });

  tearDown(() {
    Directory.current = originalCwd;
    tempDir.deleteSync(recursive: true);
  });

  test('query.run returns 64 for an unknown verb and lists valid verbs', () {
    final stderr = _TestStderr();
    final exitCode = IOOverrides.runZoned(
      () => query.run(['unknown']),
      stderr: () => stderr,
    );
    expect(exitCode, 64);
    final err = stderr.buffer.toString();
    expect(err, contains('unknown verb: unknown'));
    expect(
      err,
      contains(
        'valid verbs: readers, provider, wiring, route, impls, find, sym, path, unused, untested',
      ),
    );
  });

  test('query.run returns 64 when no verb is given and lists valid verbs', () {
    final stderr = _TestStderr();
    final exitCode = IOOverrides.runZoned(
      () => query.run([]),
      stderr: () => stderr,
    );
    expect(exitCode, 64);
    final err = stderr.buffer.toString();
    expect(err, contains('usage: <verb> [args]'));
    expect(
      err,
      contains(
        'valid verbs: readers, provider, wiring, route, impls, find, sym, path, unused, untested',
      ),
    );
  });
}
