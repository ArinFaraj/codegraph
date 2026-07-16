// `codegraph callchain <Symbol> [--depth N]` — a static call-tree from an entry
// method, one hop per callee, annotating each method with the control-flow
// HAZARDS visible without type resolution: an early-return guard, a try/catch, a
// swallowed (empty-body) catch, and fire-and-forget `unawaited(...)`.
//
// It does NOT do dataflow. It answers the question every debug/trace task hit
// ("what actually runs when this is called, and where might it early-out / skip
// / swallow?") by handing the agent the SHAPE of the flow + the exact bodies
// worth reading — so 6 blind method reads become 1-2 targeted ones.
//
// One parse pass builds name -> {callees, hazards, site}; the walk is pure map
// traversal (cycle-guarded, depth-capped). Syntax-only, so callees resolve by
// NAME: a callee with one repo declaration is followed; an ambiguous name is
// shown but not guessed into; an unresolved name (SDK/external) is a leaf.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'cli_util.dart';
import 'freshness.dart';
import 'nested_function_boundary.dart';

class _Method {
  _Method(this.name, this.file, this.line, this.callees, this.hazards);
  final String name;
  final String file;
  final int line;
  final List<String> callees; // callee method names, in source order, deduped
  final List<String> hazards; // 'guard' | 'try' | 'swallow' | 'async'
}

/// Collects, for one method/function body: the callee names it invokes and its
/// control-flow hazards.
class _BodyScan extends RecursiveAstVisitor<void> with NestedFunctionBoundary {
  final callees = <String>[];
  final seen = <String>{};
  bool tryCatch = false, emptyCatch = false, unawaited = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final n = node.methodName.name;
    if (n == 'unawaited') unawaited = true;
    if (seen.add(n)) callees.add(n);
    super.visitMethodInvocation(node);
  }

  @override
  void visitTryStatement(TryStatement node) {
    tryCatch = true;
    for (final c in node.catchClauses) {
      if (c.body.statements.isEmpty) emptyCatch = true;
    }
    super.visitTryStatement(node);
  }

  // Hazards inside nested closures/local functions are not this method's —
  // see [NestedFunctionBoundary].
}

/// True when a block has a `return` that is not its final statement — a guard /
/// early-out that skips the rest (the classic "why was the next step skipped").
bool _hasEarlyReturn(FunctionBody body) {
  if (body is! BlockFunctionBody) return false;
  final stmts = body.block.statements;
  for (var i = 0; i < stmts.length; i++) {
    // A bare `return;`/`return x;` anywhere but the last position, OR any return
    // nested in an if/loop, is an early-out. Cheap check: a ReturnStatement that
    // isn't the final top-level statement, or one nested inside a control node.
    final s = stmts[i];
    if (s is ReturnStatement && i != stmts.length - 1) return true;
    if (s is IfStatement || s is ForStatement || s is WhileStatement) {
      final finder = _ReturnFinder();
      s.accept(finder);
      if (finder.found) return true;
    }
  }
  return false;
}

class _ReturnFinder extends RecursiveAstVisitor<void>
    with NestedFunctionBoundary {
  bool found = false;
  @override
  void visitReturnStatement(ReturnStatement node) => found = true;
}

List<String> _dartFiles(Iterable<String> paths) => [
      for (final p in paths)
        if (p.endsWith('.dart') && File(p).existsSync()) p,
    ];

/// Parse every graph file once and index every method/function declaration by
/// name -> its call/hazard record (a name may have several declarations).
Map<String, List<_Method>> _buildCallGraph(Iterable<String> files) {
  final index = <String, List<_Method>>{};
  for (final path in files) {
    final String content;
    try {
      content = File(path).readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final unit = parseString(content: content, throwIfDiagnostics: false).unit;
    final li = unit.lineInfo;
    void record(String name, int offset, FunctionBody body) {
      final scan = _BodyScan();
      body.accept(scan);
      final hazards = <String>[
        if (_hasEarlyReturn(body)) 'guard',
        if (scan.tryCatch) 'try',
        if (scan.emptyCatch) 'swallow',
        if (scan.unawaited) 'async',
      ];
      index.putIfAbsent(name, () => []).add(
            _Method(name, path, li.getLocation(offset).lineNumber, scan.callees,
                hazards),
          );
    }

    for (final d in unit.declarations) {
      List<ClassMember>? members;
      if (d is FunctionDeclaration) {
        record(d.name.lexeme, d.name.offset, d.functionExpression.body);
      } else if (d is ClassDeclaration) {
        members = d.body.members;
      } else if (d is MixinDeclaration) {
        members = d.body.members;
      } else if (d is ExtensionDeclaration) {
        members = d.body.members;
      }
      for (final m in members ?? const <ClassMember>[]) {
        if (m is MethodDeclaration) {
          record(m.name.lexeme, m.name.offset, m.body);
        }
      }
    }
  }
  return index;
}

int run(List<String> args) {
  final positional = positionalArgs(args);
  final depth = intFlag(args, '--depth') ?? 3;
  final budget = intFlag(args, '--budget') ?? 120;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: callchain <Symbol> [--depth N]');
    return 64;
  }
  final symbol = positional[1];

  final graph = loadFresh();
  if (graph == null) return 66;
  final files = _dartFiles({
    for (final n in graph.nodes)
      if (n.isFile) n.id.replaceFirst('file:', ''),
  });

  final index = _buildCallGraph(files);
  final entries = index[symbol];
  if (entries == null || entries.isEmpty) {
    stdout.writeln('no method/function named "$symbol" found — '
        'it may be a class/provider (try `find`/`callers`), or external.');
    return 0;
  }

  final lines = <String>[];
  final jsonRoots = <Map<String, dynamic>>[];
  var nodeCount = 0;
  var truncated = false;

  Map<String, dynamic>? walk(
      String name, int d, List<String> path, String pad) {
    if (nodeCount >= budget) {
      truncated = true;
      return null;
    }
    final decls = index[name];
    // Unresolved (external/SDK) — a leaf, shown without a site.
    if (decls == null) {
      nodeCount++;
      lines.add('$pad$name  (external)');
      return {'name': name, 'external': true};
    }
    // Ambiguous — more than one repo declaration; never guess which, don't
    // explode into all. Show it and stop this branch. Unconditional on depth:
    // a wrong edge is a blocker, so a name that's ambiguous at the depth cap
    // (d == 0, the common leaf position) must refuse just like it does at any
    // other depth - not silently fall through to decls.first.
    if (decls.length > 1) {
      nodeCount++;
      lines.add('$pad$name  (${decls.length} declarations — ambiguous)');
      return {'name': name, 'ambiguous': decls.length};
    }
    final m = decls.first;
    nodeCount++;
    final haz = m.hazards.isEmpty ? '' : '  [${m.hazards.join(' ')}]';
    lines.add('$pad$name  (${m.file}:${m.line})$haz');
    final node = <String, dynamic>{
      'name': name,
      'site': '${m.file}:${m.line}',
      if (m.hazards.isNotEmpty) 'hazards': m.hazards,
    };
    if (d <= 0) {
      if (m.callees.any(index.containsKey)) {
        lines.add('$pad  … (depth cap — raise --depth)');
      }
      return node;
    }
    if (path.contains(name)) {
      lines.add('$pad  ↺ (recurses)');
      node['recurses'] = true;
      return node;
    }
    final children = <Map<String, dynamic>>[];
    for (final callee in m.callees) {
      // Only descend into callees the repo declares; skip the long tail of
      // SDK/framework calls to keep the tree about THIS codebase's flow.
      if (!index.containsKey(callee)) continue;
      final child = walk(callee, d - 1, [...path, name], '$pad  ');
      if (child != null) children.add(child);
    }
    if (children.isNotEmpty) node['calls'] = children;
    return node;
  }

  final ambiguousEntry = entries.length > 1;
  if (ambiguousEntry) {
    lines.add('$symbol has ${entries.length} declarations — showing each:');
  }
  for (final e in entries) {
    // Seed the walk at this specific declaration (bypass the ambiguity guard
    // for the ROOT so an explicitly-named entry still expands).
    final scanPad = ambiguousEntry ? '  ' : '';
    if (ambiguousEntry) {
      final haz = e.hazards.isEmpty ? '' : '  [${e.hazards.join(' ')}]';
      lines.add('$scanPad$symbol  (${e.file}:${e.line})$haz');
    }
    final root = <String, dynamic>{
      'name': symbol,
      'site': '${e.file}:${e.line}'
    };
    if (e.hazards.isNotEmpty) root['hazards'] = e.hazards;
    final kids = <Map<String, dynamic>>[];
    if (!ambiguousEntry) {
      final haz = e.hazards.isEmpty ? '' : '  [${e.hazards.join(' ')}]';
      lines.add('$symbol  (${e.file}:${e.line})$haz');
    }
    if (depth > 0) {
      for (final callee in e.callees) {
        if (!index.containsKey(callee)) continue;
        final child = walk(callee, depth - 1, [symbol], '$scanPad  ');
        if (child != null) kids.add(child);
      }
    }
    if (kids.isNotEmpty) root['calls'] = kids;
    jsonRoots.add(root);
  }

  if (asJson) {
    stdout.writeln(jsonEncode({
      ...envelope('callchain', symbol),
      'depth': depth,
      'resolution': 'name-based (approximate; not type-resolved)',
      'legend': {
        'guard': 'early-return before end',
        'try': 'try/catch',
        'swallow': 'empty catch (exception swallowed)',
        'async': 'unawaited(...) fire-and-forget',
      },
      'roots': jsonRoots,
      if (truncated) 'truncated': true,
    }));
    return 0;
  }

  stdout.writeln('callchain: $symbol  (depth $depth)');
  stdout.writeln('flags [guard try swallow async] mark bodies worth reading; '
      'callees are NAME-resolved (approximate — a branch may follow a '
      'same-named method on another type; read the flagged bodies to confirm)');
  emit(lines, budget, hint: 'raise --budget/--depth');
  if (truncated) stdout.writeln('  (node budget hit — raise --budget)');
  return 0;
}
