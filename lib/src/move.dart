// `rename <file.dart> <new/path.dart>`: moves a file, rewrites every import,
// export and conditional import that points at it, and fixes the moved
// file's own relative imports. Applying re-analyzes the moved file and every
// file that was rewritten, and puts everything back if an error appeared.
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';

import 'edits.dart';
import 'engine.dart';
import 'rename.dart' show Refusal, RefusalAnswer, RefusalKind;
import 'request.dart';
import 'result.dart';
import 'symbols.dart';
import 'verify.dart';

class MoveRequest extends WorkerRequest {
  MoveRequest(
    this.from,
    this.to, {
    required this.apply,
    required super.json,
    required super.limit,
  });

  MoveRequest.fromJson(Map<String, dynamic> j)
    : this(
        j['from'] as String,
        j['to'] as String,
        apply: j['apply'] as bool,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  final String from;
  final String to;
  final bool apply;

  @override
  String get verb => 'move';

  @override
  Map<String, Object?> get fields => {'from': from, 'to': to, 'apply': apply};

  @override
  Future<Answer> run(Engine engine) => move(engine, from, to, apply: apply);
}

/// One URI string literal to rewrite.
class UriEdit {
  UriEdit(this.path, this.offset, this.line, this.before, this.after);

  /// Workspace-relative file holding the literal, at its location before the
  /// move.
  final String path;
  final int offset;
  final int line;

  /// The literal as written, quotes included, and its replacement.
  final String before;
  final String after;
}

class MovePlan {
  MovePlan(this.from, this.to, this.text, this.importers, this.own);

  final String from;
  final String to;

  /// The moved file's text when the plan was made.
  final String text;

  /// Edits in files that point at the moved file.
  final List<UriEdit> importers;

  /// Edits to the moved file's own relative imports and exports.
  final List<UriEdit> own;

  List<String> get rewrittenFiles =>
      importers.map((e) => e.path).toSet().toList()..sort();
}

sealed class MovePlanning {}

class MoveReady extends MovePlanning {
  MoveReady(this.plan);
  final MovePlan plan;
}

class MoveStopped extends MovePlanning {
  MoveStopped(this.answer);
  final Answer answer;
}

Future<Answer> move(
  Engine engine,
  String from,
  String to, {
  required bool apply,
}) async => switch (planMove(engine, from, to)) {
  MoveStopped(:final answer) => answer,
  MoveReady(:final plan) => MoveAnswer(
    plan,
    apply ? await applyMove(engine, plan) : null,
  ),
};

MovePlanning planMove(Engine engine, String fromArg, String toArg) {
  final ws = engine.workspace;
  MoveStopped usage(String message) =>
      MoveStopped(MessageAnswer('rename', message, exit: Exit.usage));

  final candidates = fileCandidates(ws, engine.analysis.files, fromArg);
  if (candidates.length != 1) {
    return MoveStopped(FileChoiceAnswer('rename', fromArg, candidates));
  }
  final from = candidates.single;
  final to = ws.relativeOrNull(toArg);
  if (to == null) return usage('$toArg is outside the workspace');
  if (!to.endsWith('.dart')) return usage('$toArg is not a .dart path');
  if (to == from) return usage('$from is already at $to');
  if (FileSystemEntity.typeSync(ws.absolute(to)) !=
      FileSystemEntityType.notFound) {
    return usage('$to already exists');
  }
  final unit = engine.sources.unit(from);
  if (unit.directives.any((d) => d is PartDirective || d is PartOfDirective)) {
    return MoveStopped(
      RefusalAnswer(
        Refusal(
          RefusalKind.unsupported,
          '$from has parts or is a part; move the library and its parts by '
          'hand',
        ),
      ),
    );
  }

  final packages = ws.packageRoots();
  String uriFor(String importer, String original) {
    if (original.startsWith('package:')) {
      final abs = ws.absolute(to);
      for (final e in packages.entries) {
        if (abs.startsWith('${e.value}/lib/')) {
          return 'package:${e.key}/${abs.substring(e.value.length + 5)}';
        }
      }
    }
    return relativeUri(importer, to);
  }

  final name = from.split('/').last;
  final importers = <UriEdit>[];
  for (final path in engine.analysis.files) {
    if (path == from || !engine.sources.text(path).contains(name)) continue;
    for (final literal in uriLiterals(engine.sources.unit(path))) {
      final uri = literal.stringValue;
      if (uri == null || engine.outline.resolveUri(path, uri) != from) {
        continue;
      }
      importers.add(_edit(engine, path, literal, uriFor(path, uri)));
    }
  }

  final own = <UriEdit>[];
  for (final literal in uriLiterals(unit)) {
    final uri = literal.stringValue;
    if (uri == null || uri.contains(':')) continue;
    final target = ws.relativeOrNull('${_dir(ws.absolute(from))}/$uri');
    if (target == null) continue;
    final rewritten = relativeUri(to, target);
    if (rewritten != uri) own.add(_edit(engine, from, literal, rewritten));
  }
  return MoveReady(
    MovePlan(from, to, engine.sources.text(from), importers, own),
  );
}

/// The URI literals of every import and export, conditional ones included.
Iterable<SimpleStringLiteral> uriLiterals(CompilationUnit unit) sync* {
  for (final d in unit.directives) {
    if (d is! NamespaceDirective) continue;
    if (d.uri case final SimpleStringLiteral uri) yield uri;
    for (final c in d.configurations) {
      if (c.uri case final SimpleStringLiteral uri) yield uri;
    }
  }
}

UriEdit _edit(
  Engine engine,
  String path,
  SimpleStringLiteral literal,
  String uri,
) {
  final lexeme = literal.literal.lexeme;
  final quote = lexeme.indexOf(RegExp('[\'"]'));
  final open = lexeme.substring(0, quote + 1);
  final close = lexeme.substring(quote, quote + 1);
  return UriEdit(
    path,
    literal.offset,
    engine.sources.lineOf(path, literal.offset),
    lexeme,
    '$open$uri$close',
  );
}

/// A relative URI from the file [fromFile] to [toFile], both
/// workspace-relative.
String relativeUri(String fromFile, String toFile) {
  final from = fromFile.split('/')..removeLast();
  final to = toFile.split('/');
  var common = 0;
  while (common < from.length &&
      common < to.length - 1 &&
      from[common] == to[common]) {
    common++;
  }
  return [
    for (var i = common; i < from.length; i++) '..',
    ...to.sublist(common),
  ].join('/');
}

String _dir(String path) => path.substring(0, path.lastIndexOf('/'));

Future<Applied> applyMove(Engine engine, MovePlan plan) async {
  final ws = engine.workspace;
  final fromFile = File(ws.absolute(plan.from));
  final toFile = File(ws.absolute(plan.to));
  final rewritten = plan.rewrittenFiles;
  final baseline = await ErrorBaseline.take(engine, [plan.from, ...rewritten]);

  if (fromFile.readAsStringSync() != plan.text) {
    return NotApplied('source changed since it was analyzed', [plan.from]);
  }
  var moved = plan.text;
  for (final e in plan.own.toList()..sort((a, b) => b.offset - a.offset)) {
    moved = moved.replaceRange(e.offset, e.offset + e.before.length, e.after);
  }

  final PreparedTextEdits prepared;
  try {
    prepared = prepareTextEdits([
      for (final e in plan.importers)
        AtomicTextEdit(
          file: ws.absolute(e.path),
          offset: e.offset,
          length: e.before.length,
          expected: e.before,
          replacement: e.after,
        ),
    ]);
  } on AtomicEditException catch (e) {
    return NotApplied(e.message, e.details);
  }

  final createdDirs = _missingDirs(toFile.parent);
  void undoCreate() {
    if (toFile.existsSync()) toFile.deleteSync();
    for (final d in createdDirs.reversed) {
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    }
  }

  try {
    toFile.parent.createSync(recursive: true);
    toFile.createSync(exclusive: true);
    toFile.writeAsStringSync(moved);
    applyPreparedTextEdits(prepared);
  } on Object catch (e) {
    undoCreate();
    return NotApplied('the move could not be written: $e', const []);
  }
  fromFile.deleteSync();

  Future<RolledBack> rollBack(List<String> why) async {
    fromFile.writeAsStringSync(plan.text);
    undoCreate();
    restorePreparedTextEdits(prepared);
    await engine.refresh();
    return RolledBack(why);
  }

  await engine.refresh();
  if (!engine.analysis.isAnalyzed(plan.to)) {
    return rollBack([
      '${plan.to} is not analyzed (excluded, or outside a package), so the '
          'move could not be checked',
    ]);
  }
  final introduced = await baseline.introduced(
    engine,
    renamed: {plan.from: plan.to},
  );
  if (introduced.isNotEmpty) return rollBack(introduced);
  _removeEmptyDirs(fromFile.parent, ws.root);
  return AppliedClean(baseline.fileCount);
}

/// Deletes [dir] and its parents while they are empty, stopping at [root].
void _removeEmptyDirs(Directory dir, String root) {
  for (var d = dir; d.path.startsWith('$root/'); d = d.parent) {
    if (!d.existsSync() || d.listSync().isNotEmpty) return;
    d.deleteSync();
  }
}

/// [dir] and the ancestors of it that do not exist yet, outermost first.
List<Directory> _missingDirs(Directory dir) {
  final out = <Directory>[];
  for (var d = dir; !d.existsSync(); d = d.parent) {
    out.insert(0, d);
  }
  return out;
}

class MoveAnswer extends Answer {
  MoveAnswer(this.plan, this.applied);

  final MovePlan plan;

  /// Null for a dry run.
  final Applied? applied;

  @override
  String get verb => 'rename';

  @override
  int get exit => switch (applied) {
    null || AppliedClean() => Exit.ok,
    RolledBack() => Exit.refused,
    NotApplied() => Exit.failed,
  };

  @override
  void write(TextOut out) {
    final files = plan.rewrittenFiles.length;
    out.header(
      '${applied == null ? 'would move' : 'moving'} ${plan.from} -> '
      '${plan.to}: rewrites ${plural(plan.importers.length, 'import')} in '
      '${plural(files, 'file')}'
      '${plan.own.isEmpty ? '' : ' and ${plural(plan.own.length, 'import')} of its own'}'
      '${applied == null ? ' (dry run; --apply to write)' : ''}',
    );
    for (final e in [...plan.importers, ...plan.own]) {
      out.row('  ${e.path}:${e.line}  ${e.before} -> ${e.after}');
    }
    switch (applied) {
      case null:
        break;
      case AppliedClean(:final checkedFiles):
        out.footer(
          'moved. Analysis of ${plural(checkedFiles, 'affected file')} '
          'shows no new errors.',
        );
      case RolledBack(:final errors):
        out.footer('rolled back: every file is as it was:');
        for (final e in errors.take(15)) {
          out.footer('  $e');
        }
      case NotApplied(:final message, :final details):
        out.footer('not applied: $message');
        for (final d in details) {
          out.footer('  $d');
        }
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'from': plan.from,
    'to': plan.to,
    'edits': [
      for (final e in [...plan.importers, ...plan.own])
        {'path': e.path, 'line': e.line, 'before': e.before, 'after': e.after},
    ],
    if (applied != null)
      'applied': switch (applied!) {
        AppliedClean(:final checkedFiles) => {
          'result': 'applied',
          'checkedFiles': checkedFiles,
        },
        RolledBack(:final errors) => {
          'result': 'rolled back',
          'errors': errors,
        },
        NotApplied(:final message, :final details) => {
          'result': 'not applied',
          'message': message,
          'details': details,
        },
      },
  };
}
