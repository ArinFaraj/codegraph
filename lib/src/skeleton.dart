// `codegraph skeleton <file>` — per-file outline (declarations + line
// numbers), so an agent can see a file's shape without a full Read.
//
// Only file here that imports the analyzer directly for query-side use;
// query.dart itself stays dart:core/convert/io only — it must run fast and
// without a fresh parse for every other verb, which only reads the
// pre-built graph JSON.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'cli_util.dart'
    show emit, envelope, freshnessClause, intFlag, positionalArgs;
import 'freshness.dart';
import 'model.dart';
import 'resolve.dart';

/// `int run(List<String> args)` — resolve + parse + print a file's outline.
int run(List<String> args) {
  final positional = positionalArgs(args);
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: skeleton <file-substring>');
    return 64;
  }
  final arg = positional[1];

  final graph = loadFresh();
  if (graph == null) return 66;

  final String path;
  switch (resolveFileArg(graph, arg)) {
    case NotFoundFile():
      stdout.writeln('no file matches "$arg" '
          '(${freshnessClause(graph.stats['files'] ?? 0)}) — try `find $arg`');
      return 0;
    case AmbiguousFile(:final candidates):
      printAmbiguous(arg, candidates, cap: budget);
      return 2;
    case ResolvedFile(path: final p):
      path = p;
  }

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('$path no longer exists on disk — run: codegraph build');
    return 1;
  }

  final content = file.readAsStringSync();
  final lineCount = '\n'.allMatches(content).length + 1;
  final parsed = parseString(content: content, throwIfDiagnostics: false);
  final unit = parsed.unit;
  final lineInfo = unit.lineInfo;

  final lines = <String>[];
  for (final d in unit.declarations) {
    if (d is ClassDeclaration) {
      lines.add(
        '${lineOf(lineInfo, d.namePart.offset)}: ${renderClassSig(d)}',
      );
      for (final m in renderMembers(
            d.body.members,
            lineInfo,
            d.namePart.toSource().split('<').first.trim(),
            includePrivate: true,
          ) ??
          const <String>[]) {
        lines.add('  $m');
      }
    } else if (d is MixinDeclaration) {
      lines.add('${lineOf(lineInfo, d.name.offset)}: ${renderMixinSig(d)}');
      for (final m in renderMembers(
            d.body.members,
            lineInfo,
            d.name.lexeme,
            includePrivate: true,
          ) ??
          const <String>[]) {
        lines.add('  $m');
      }
    } else if (d is EnumDeclaration) {
      lines.add(
        '${lineOf(lineInfo, d.namePart.offset)}: ${renderEnumSig(d)}',
      );
      for (final m in renderMembers(
            d.body.members,
            lineInfo,
            d.namePart.toSource().split('<').first.trim(),
            includePrivate: true,
          ) ??
          const <String>[]) {
        lines.add('  $m');
      }
    } else if (d is ExtensionDeclaration) {
      lines.add('${lineOf(lineInfo, d.offset)}: ${renderExtensionSig(d)}');
      for (final m in renderMembers(
            d.body.members,
            lineInfo,
            d.name?.lexeme ?? '',
            includePrivate: true,
          ) ??
          const <String>[]) {
        lines.add('  $m');
      }
    } else if (d is ExtensionTypeDeclaration) {
      lines.add(
        '${lineOf(lineInfo, d.primaryConstructor.typeName.offset)}: '
        '${renderExtensionTypeSig(d)}',
      );
      for (final m in renderMembers(
            d.body.members,
            lineInfo,
            d.primaryConstructor.typeName.lexeme,
            includePrivate: true,
          ) ??
          const <String>[]) {
        lines.add('  $m');
      }
    } else if (d is TypeAlias) {
      lines.add('${lineOf(lineInfo, d.name.offset)}: ${renderTypedefSig(d)}');
    } else if (d is FunctionDeclaration) {
      lines.add(
        '${lineOf(lineInfo, d.name.offset)}: ${renderFunctionSig(d)}',
      );
    }
  }

  if (asJson) {
    final capped = lines.take(budget).toList();
    stdout.writeln(
      jsonEncode({
        ...envelope('skeleton', arg),
        'file': path,
        'lines': lineCount,
        'declarations': capped,
        if (lines.length > budget) 'truncated': lines.length - budget,
      }),
    );
    return 0;
  }

  stdout.writeln('$path  ($lineCount lines)');
  emit(
    lines,
    budget,
    hint: 'raise --budget ${lines.length}',
  );
  return 0;
}
