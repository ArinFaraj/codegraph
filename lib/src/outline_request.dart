// `find` and `show` answered by a running worker from the outline it keeps in
// memory, so they skip reading the outline cache from disk. Without a ready
// worker the client answers the same verbs from that cache itself.
import 'args.dart';
import 'engine.dart';
import 'find.dart';
import 'outline.dart';
import 'request.dart';
import 'result.dart';
import 'show.dart';
import 'show_file.dart';

class OutlineRequest extends WorkerRequest {
  OutlineRequest(
    this.outlineVerb,
    this.arg, {
    required super.json,
    required super.limit,
  });

  OutlineRequest.fromJson(Map<String, dynamic> j)
    : this(
        j['outlineVerb'] as String,
        j['arg'] as String,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  /// `find` or `show`.
  final String outlineVerb;
  final String arg;

  @override
  String get verb => 'outline';

  @override
  Map<String, Object?> get fields => {'outlineVerb': outlineVerb, 'arg': arg};

  @override
  Future<Answer> run(Engine engine) async => outlineVerb == 'find'
      ? find(engine.outline, arg)
      : showPath(engine.outline, arg) ?? await showSymbol(engine, arg);
}

/// `show` of the file or directory [arg] names, or null when it names a
/// symbol.
Answer? showPath(OutlineIndex idx, String arg) =>
    switch (classifyArg(idx, arg, directories: true)) {
      FileArg(:final path) => showFile(idx, path),
      DirArg(:final path) => showArea(idx, path),
      ChoiceArg(:final candidates) => FileChoiceAnswer('show', arg, candidates),
      SymbolArg() => null,
    };
