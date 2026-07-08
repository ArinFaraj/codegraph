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

import 'model.dart';

int? _intFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return int.tryParse(args[i + 1]);
  return null;
}

/// Resolves `arg` against file nodes in the graph exactly like `query.dart`'s
/// `_path`'s resolve: unique substring, exact-suffix tiebreak, else ambiguous
/// list. Returns the bare (non-`file:`-prefixed) path, or `null`.
String? _resolve(List<GraphNode> nodes, String arg, int budget) {
  final hits = nodes
      .where((n) => n.isFile && n.id.contains(arg))
      .map((n) => n.id)
      .toList();
  if (hits.length == 1) return hits.first.replaceFirst('file:', '');
  final exact = hits.where((h) => h.endsWith('/$arg') || h.endsWith(':$arg'));
  if (exact.length == 1) return exact.first.replaceFirst('file:', '');
  if (hits.length > 1) {
    stdout.writeln('"$arg" is ambiguous (${hits.length} files):');
    for (final h in hits.take(budget)) {
      stdout.writeln('  ${h.replaceFirst('file:', '')}');
    }
  }
  return null;
}

/// `int run(List<String> args)` — resolve + parse + print a file's outline.
int run(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = _intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: skeleton <file-substring>');
    return 64;
  }
  final arg = positional[1];

  final graph = Graph.load();
  if (graph == null) return 66;
  final nodes = graph.nodes;

  final path = _resolve(nodes, arg, budget);
  if (path == null) {
    if (nodes.every((n) => !n.isFile || !n.id.contains(arg))) {
      stdout.writeln('no file matches "$arg" — try `find $arg`');
    }
    return 0;
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
        'verb': 'skeleton',
        'query': arg,
        'file': path,
        'lines': lineCount,
        'declarations': capped,
        if (lines.length > budget) 'truncated': lines.length - budget,
      }),
    );
    return 0;
  }

  stdout.writeln('$path  ($lineCount lines)');
  _emit(
    lines,
    budget,
    hint: 'raise --budget ${lines.length}',
  );
  return 0;
}

void _emit(List<String> lines, int budget, {String? hint}) {
  for (final l in lines.take(budget)) {
    stdout.writeln(l);
  }
  if (lines.length > budget) {
    stdout.writeln(
      '… ${lines.length - budget} more (raise --budget to see all)',
    );
    if (hint != null) stdout.writeln('  ($hint)');
  }
}
