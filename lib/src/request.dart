import 'engine.dart';
import 'result.dart';

/// A question for the worker, already classified by the client. Each verb
/// defines its own request next to the code that answers it.
abstract class WorkerRequest {
  WorkerRequest({required this.json, required this.limit});

  final bool json;
  final int? limit;

  String get verb;

  /// The verb's own fields, as they travel to the worker.
  Map<String, Object?> get fields;

  Future<Answer> run(Engine engine);

  Map<String, Object?> toJson() => {
    'verb': verb,
    'json': json,
    'limit': limit,
    ...fields,
  };
}
