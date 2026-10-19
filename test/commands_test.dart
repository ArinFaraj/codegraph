import 'package:codegraph/src/commands.dart';
import 'package:codegraph/src/impact.dart';
import 'package:test/test.dart';

void main() {
  test('flags are separated from arguments', () {
    final c = Command.parse(['rename', 'A.b', 'c', '--apply', '--limit', '5']);
    expect(c.verb, 'rename');
    expect(c.args, ['A.b', 'c']);
    expect(c.apply, isTrue);
    expect(c.limit, 5);
    expect(Command.parse(['refs', 'x', '--all']).limit, isNull);
    expect(Command.parse(['impact', '--base', 'dev']).diff, isTrue);
    expect(Command.parse(['refs', '--bogus']).error, 'unknown flag --bogus');
  });

  test('every worker request survives the trip to the worker', () {
    final requests = <WorkerRequest>[
      RefsRequest('x', json: true, limit: null),
      ShowRequest('A.b', json: false, limit: 40),
      ImpactRequest(SymbolSeed('x'), json: false, limit: 40),
      ImpactRequest(FileSeed('lib/a.dart'), json: false, limit: 40),
      ImpactRequest(DiffSeed('dev'), json: false, limit: 40),
      RenameRequest('a', 'b', apply: true, json: false, limit: 40),
    ];
    for (final r in requests) {
      expect(WorkerRequest.fromJson(r.toJson()).toJson(), r.toJson());
    }
  });
}
