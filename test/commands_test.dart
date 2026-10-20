import 'package:codegraph/src/commands.dart';
import 'package:test/test.dart';

void main() {
  test('flags are separated from arguments', () {
    final c = Command.parse(['rename', 'A.b', 'c', '--apply', '--limit', '5']);
    expect(c.verb, 'rename');
    expect(c.args, ['A.b', 'c']);
    expect(c.apply, isTrue);
    expect(c.limit, 5);
    expect(Command.parse(['refs', 'x', '--all']).limit, isNull);
    expect(Command.parse(['refs', '--bogus']).error, 'unknown flag --bogus');
  });

  test('a command survives the trip to the worker', () {
    final commands = [
      Command.parse(['refs', 'x', '--json', '--all', '-C', '2']),
      Command.parse(['rename', 'lib/a.dart', 'lib/b.dart', '--apply']),
      Command('check', ['/r/lib/a.dart'], limit: 30, since: DateTime(2026)),
    ];
    for (final c in commands) {
      expect(Command.fromJson(c.toJson()).toJson(), c.toJson());
    }
  });

  test('each verb checks its own arguments', () {
    bool accepts(List<String> argv) =>
        workerVerbs[argv.first]!.accepts(Command.parse(argv));
    expect(accepts(['refs', 'x']), isTrue);
    expect(accepts(['refs', 'x', 'y']), isFalse);
    expect(accepts(['rename', 'a']), isFalse);
    expect(accepts(['check', 'lib/a.dart', '--all']), isFalse);
    expect(accepts(['check', '--all']), isTrue);
  });
}
