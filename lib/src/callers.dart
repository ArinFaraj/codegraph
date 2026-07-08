// `codegraph callers <Symbol>` / `refs <Symbol>` — symbol-precise call sites.
//
// The single most-requested missing capability across every eval round: `find`
// gives a symbol's DECLARATION, `readers` gives PROVIDER edges, `impact` gives
// WHOLE-FILE blast radius — none answers "who calls THIS method?" (`revokeSession`,
// `handleResume`, …), which every refactor/debug/trace task forced to grep.
//
// This is an on-demand AST scan (like `skeleton`, no graph bloat): it parses the
// graph's files PLUS the test roots (a signature change breaks tests too — those
// dirs are outside the graph) and matches call sites / references by NAME. Being
// AST-based it beats grep: no comment/string false hits, and it distinguishes a
// CALL (`x()`) from a REFERENCE (tear-off / type / switch case). Syntax-only, so
// matching is by name — for an ambiguous name it reports how many declarations
// exist so the agent knows the list spans them.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'cli_util.dart';
import 'model.dart';

const _testRoots = ['test', 'integration_test', 'patrol_test'];

class _Hit {
  _Hit(this.file, this.line, this.kind, this.text);
  final String file;
  final int line;
  final String kind; // 'call' | 'ref'
  final String text; // trimmed source line
}

class _Finder extends RecursiveAstVisitor<void> {
  _Finder(this.symbol, this.lineInfo, this.file, this.lines, this.hits,
      this.refsMode);
  final String symbol;
  final LineInfo lineInfo;
  final String file;
  final List<String> lines; // source lines for context text
  final List<_Hit> hits;
  final bool refsMode;

  String _lineText(int line) =>
      (line >= 1 && line <= lines.length) ? lines[line - 1].trim() : '';

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == symbol) {
      final line = lineInfo.getLocation(node.methodName.offset).lineNumber;
      hits.add(_Hit(file, line, 'call', _lineText(line)));
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (refsMode && node.name == symbol) {
      final p = node.parent;
      // Skip the CALL name (already recorded as 'call') and declaration names
      // (the definition, not a use).
      final isCallName = p is MethodInvocation && identical(p.methodName, node);
      final isDeclName = (p is MethodDeclaration && identical(p.name, node)) ||
          (p is FunctionDeclaration && identical(p.name, node)) ||
          (p is VariableDeclaration && identical(p.name, node)) ||
          (p is NamedType); // don't double-list a type at its own decl site
      if (!isCallName && !isDeclName) {
        final line = lineInfo.getLocation(node.offset).lineNumber;
        hits.add(_Hit(file, line, 'ref', _lineText(line)));
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

List<File> _dartFilesUnder(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// `int run(List<String> args)` — `callers|refs <Symbol> [--json] [--budget N]`.
int run(List<String> args) {
  final verb = args.isNotEmpty ? args.first : 'callers';
  final refsMode = verb == 'refs';
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: $verb <Symbol>');
    return 64;
  }
  final symbol = positional[1];

  final graph = Graph.load();
  if (graph == null) return 66;

  // Scope: every file the graph knows (lib/ + packages/*/lib) PLUS the test
  // roots (outside the graph — but a signature change breaks tests too).
  final paths = <String>{
    for (final n in graph.nodes)
      if (n.isFile) n.id.replaceFirst('file:', ''),
  };
  final files = <File>[
    for (final p in paths)
      if (File(p).existsSync()) File(p),
    for (final root in _testRoots) ..._dartFilesUnder(root),
  ];

  final hits = <_Hit>[];
  for (final f in files) {
    final String content;
    try {
      content = f.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    // Cheap pre-filter: no textual occurrence → skip the parse entirely.
    if (!content.contains(symbol)) continue;
    final unit = parseString(content: content, throwIfDiagnostics: false).unit;
    final lines = content.split('\n');
    final rel = f.path.startsWith('./') ? f.path.substring(2) : f.path;
    unit.accept(_Finder(symbol, unit.lineInfo, rel, lines, hits, refsMode));
  }

  // Declarations of this name — top-level symbols AND class/mixin/extension
  // members — so an ambiguous name is flagged (call sites span all same-named
  // declarations under syntax-only).
  final decls = graph.declarationsOf(symbol);

  // Rank: by containing file in-degree (desc), then file, then line.
  int inDeg(String file) => graph.inDeg['file:$file'] ?? 0;
  hits.sort((a, b) {
    final byDeg = inDeg(b.file).compareTo(inDeg(a.file));
    if (byDeg != 0) return byDeg;
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });

  if (asJson) {
    stdout.writeln(jsonEncode({
      'verb': verb,
      'query': symbol,
      'declarations': decls,
      'count': hits.length,
      'hits': [
        for (final h in hits.take(budget))
          {'file': h.file, 'line': h.line, 'kind': h.kind, 'text': h.text},
      ],
      if (hits.length > budget) 'truncated': hits.length - budget,
    }));
    return 0;
  }

  final callN = hits.where((h) => h.kind == 'call').length;
  final refN = hits.length - callN;
  final header = refsMode
      ? 'references to $symbol — $callN calls + $refN other refs'
      : 'callers of $symbol — $callN call sites';
  final out = <String>[header];
  if (decls.length > 1) {
    out.add('  (note: $symbol has ${decls.length} declarations — '
        'sites match by name across all of them)');
  }
  if (hits.isEmpty) {
    out.add('  (none — try `find $symbol`, or check the exact name)');
  }
  for (final h in hits) {
    final k = h.kind == 'ref' ? ' [ref]' : '';
    out.add('  ${h.file}:${h.line}$k  ${h.text}');
  }
  emit(out, budget, hint: 'raise --budget ${hits.length}');
  return 0;
}
