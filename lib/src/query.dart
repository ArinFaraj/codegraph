// Token-efficient query interface over the resolved code graph.
//
// Answers the questions that otherwise cost an agent many greps + file reads,
// from the canonical graph built by `codegraph build`:
//
//   codegraph readers <provider>   # who watches/reads/listens it
//   codegraph provider <name>      # declaration + all consumers
//   codegraph wiring <file>        # a file's full wiring (both directions)
//   codegraph impls <Type>         # who implements/extends a type
//   codegraph find <substr> [more terms]  # locate files/providers/symbols (incl. packages/), ranked
//   codegraph sym <Name>           # symbol card (sig + doc + members + imported-by)
//   codegraph path <A> <B>         # how two files connect
//   codegraph untested             # coverage gaps: providers/files with zero test references
//
// Add --budget N to cap output lines (default 80). Add --json to any of
// find/readers/wiring/impls/sym for a machine-readable record instead of text.
// Reads docs/maps/code_graph.json. Syntax-tree only — no analyzer import here
// (see lib/src/skeleton.dart for the one verb that needs a fresh parse).

import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'model.dart';
import 'test_impls.dart';

/// Runs a query verb (`args.first`) and returns the exit code.
int run(List<String> args) {
  final graph = Graph.load();
  if (graph == null) return 66;

  final positional = args.where((a) => !a.startsWith('--')).toList();
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  final cmd = positional.first;
  final rest = positional.skip(1).toList();

  switch (cmd) {
    case 'readers':
      _readers(graph, rest, budget, asJson);
    case 'provider':
      // Alias of `readers`; reads better when you start from the provider.
      _readers(graph, rest, budget, asJson);
    case 'wiring':
      _wiring(graph, rest, budget, asJson);
    case 'impls':
      _impls(graph, rest, budget, asJson);
    case 'find':
      _find(graph, rest, budget, asJson);
    case 'sym':
      _sym(graph, rest, budget, asJson);
    case 'path':
      _path(graph, rest);
    case 'unused':
      _unused(graph, rest, budget);
    case 'untested':
      _untested(graph, budget, asJson);
  }
  return 0;
}

void _readersInto(Graph graph, List<String> out, GraphNode decl) {
  final id = decl.id;
  final name = decl.name!;
  out.add(
    'provider $name — ${decl.providerType}'
    '${decl.autoDispose == true ? ' (autoDispose)' : ''}'
    ' — declared in ${decl.declaredIn}',
  );
  final consumers = graph.edges.where(
    (e) => e.dst == id && const {'reads', 'watches', 'listens'}.contains(e.rel),
  );
  final byRel = <String, List<String>>{};
  for (final e in consumers) {
    byRel.putIfAbsent(e.rel, () => []).add(e.src.replaceFirst('file:', ''));
  }
  for (final rel in ['watches', 'reads', 'listens']) {
    final list = (byRel[rel] ?? [])..sort();
    if (list.isEmpty) continue;
    out.add('$rel (${list.length}):');
    out.addAll(list.map((f) => '  $f'));
  }
  if (byRel.isEmpty) out.add('(no consumers found)');
}

/// Record form of one declaration's reader lists, for `--json`. [remaining]
/// is a shared budget counter across all sections (and, when there are
/// multiple declarations, across all of them too) — decremented as items are
/// taken so the total item count across every section never exceeds the
/// original `--budget`, instead of each section getting its own full budget.
Map<String, dynamic> _readersRecord(
  Graph graph,
  GraphNode decl,
  Budget remaining,
) {
  final id = decl.id;
  final byRel = <String, List<String>>{
    for (final rel in ['watches', 'reads', 'listens'])
      rel: remaining.take(
        graph.edges
            .where((e) => e.dst == id && e.rel == rel)
            .map((e) => e.src.replaceFirst('file:', ''))
            .toList()
          ..sort(),
      ),
  };
  return {
    'provider': decl.name,
    'declaredIn': decl.declaredIn,
    'line': decl.line,
    ...byRel,
  };
}

void _readers(Graph graph, List<String> rest, int budget, bool asJson) {
  if (rest.isEmpty) {
    stderr.writeln('usage: readers <provider>');
    exit(64);
  }
  final name = rest.first.replaceFirst('provider:', '');
  final decls = graph.nodes
      .where((n) => n.isProvider && n.name == name)
      .toList()
    ..sort((a, b) => a.declaredIn!.compareTo(b.declaredIn!));

  if (decls.isEmpty) {
    if (asJson) {
      stdout.writeln(
        jsonEncode({'verb': 'readers', 'query': name, 'results': []}),
      );
      return;
    }
    // Not a provider — but if it's a real symbol (widget/class/fn/…), the
    // "misspelled" wording misleads (reads as "wrong name") when the name is
    // correct. `readers` is provider-only; point at the verb that answers usage
    // for non-providers instead of implying the name is bad.
    String? symKind;
    String? symName;
    final lower = name.toLowerCase();
    findSym:
    for (final n in graph.nodes) {
      for (final s in n.symbols) {
        if (s.name.toLowerCase() == lower) {
          symKind =
              const {'fn': 'function', 'ext': 'extension'}[s.kind] ?? s.kind;
          symName = s.name;
          break findSym;
        }
      }
    }
    emit([
      symKind != null
          ? '$symName is a $symKind, not a provider — `readers` is provider-only. '
              'For its usage use `find $symName` or `wiring <file>`.'
          : 'provider $name — (not declared in lib; external or misspelled)',
    ], budget);
    return;
  }

  if (asJson) {
    final remaining = Budget(budget);
    final results =
        decls.map((d) => _readersRecord(graph, d, remaining)).toList();
    stdout.writeln(
      jsonEncode({
        'verb': 'readers',
        'query': name,
        'results': results,
        if (remaining.truncated) 'truncated': true,
      }),
    );
    return;
  }

  final out = <String>[];
  if (decls.length == 1) {
    _readersInto(graph, out, decls.single);
  } else {
    // Same name declared more than once — never merge, list each
    // declaration's own (import-reachability-resolved) readers separately.
    out.add(
      '$name is declared ${decls.length} times — readers per declaration '
      '(resolved via import reachability):',
    );
    for (final decl in decls) {
      out.add('');
      _readersInto(graph, out, decl);
    }
    final unresolved = graph.edges
        .where(
          (e) =>
              e.dst == 'provider:$name' &&
              e.isUnresolvedAmbiguous &&
              const {'reads', 'watches', 'listens'}.contains(e.rel),
        )
        .toList();
    if (unresolved.isNotEmpty) {
      out.add('');
      out.add(
        'unresolved (${unresolved.length}) — reader doesn\'t import either '
        'declaration, or imports more than one; confirm with grep:',
      );
      for (final e in unresolved) {
        out.add('  ${e.src.replaceFirst('file:', '')}  (${e.rel})');
      }
    }
  }
  final hint = _shapeChangeHint(graph, decls);
  if (hint != null) {
    out.add('');
    out.add(hint);
  }
  emit(out, budget, hint: 'raise --budget N');
}

/// For a Notifier-backed provider, `readers` lists only provider CONSUMERS
/// (`ref.watch/read/listen`). A change to the provider's STATE SHAPE also breaks
/// its Notifier subclasses and files that use the state type — neither of which
/// consumes the provider, so neither appears in `readers`. This false
/// completeness was caught by an A/B eval (an agent renaming a provider had to
/// grep to find the subclasses). Point it at the verbs that DO answer that:
/// `impls <Notifier>` (subtypes) and `sym <State>` (state-type users), naming
/// the actual classes when they can be read from the declaring file.
String? _shapeChangeHint(Graph graph, List<GraphNode> decls) {
  GraphNode? nd;
  for (final d in decls) {
    if ((d.providerType ?? '').contains('Notifier')) {
      nd = d;
      break;
    }
  }
  if (nd == null) return null;
  String? notifierClass, stateType;
  final file = graph.byId['file:${nd.declaredIn}'];
  if (file != null) {
    for (final s in file.symbols) {
      final m = RegExp(r'class\s+(\w+)\s+extends\s+\w*Notifier<([^,>]+)')
          .firstMatch(s.sig);
      if (m != null) {
        notifierClass = m.group(1);
        stateType = m.group(2)!.trim();
        break;
      }
      if (notifierClass == null && s.name.endsWith('Notifier')) {
        notifierClass = s.name; // fallback: name convention, no generic parsed
      }
    }
  }
  final impls =
      notifierClass != null ? 'impls $notifierClass' : 'impls <Notifier>';
  final sym = stateType != null ? 'sym $stateType' : 'sym <StateType>';
  return 'shape change? `readers` lists CONSUMERS only — a change to '
      '${nd.name}\'s state shape also affects its Notifier subclasses and '
      'state-type users (not shown here). Also run: `$impls` · `$sym`.';
}

/// Section-name -> sorted (full, untruncated) list of `GraphEdge.dstDisplayName`
/// strings — the record `_wiring` renders as text (global `_emit` line cap)
/// or `--json` (per-array `--budget` cap applied at serialization).
Map<String, List<String>> _wiringRecord(Graph graph, String id) {
  List<String> section(Iterable<String> items) => items.toList()..sort();
  return {
    'declares': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'declares')
          .map((e) => e.dstDisplayName),
    ),
    'watches': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'watches')
          .map((e) => e.dstDisplayName),
    ),
    'reads': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'reads')
          .map((e) => e.dstDisplayName),
    ),
    'listens': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'listens')
          .map((e) => e.dstDisplayName),
    ),
    'navigates': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'navigates')
          .map((e) => e.dstDisplayName),
    ),
    'navigates-to': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'navigates-to')
          .map((e) => e.dstDisplayName),
    ),
    'navigatesUnresolved': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'navigates' && e.unresolved)
          .map((e) => e.dstDisplayName),
    ),
    'imports': section(
      graph.edges
          .where((e) => e.src == id && e.rel == 'imports')
          .map((e) => e.dstDisplayName),
    ),
    'imported-by': section(
      graph.edges
          .where((e) => e.dst == id && e.rel == 'imports')
          .map((e) => e.src.replaceFirst('file:', '')),
    ),
  };
}

void _wiring(Graph graph, List<String> rest, int budget, bool asJson) {
  if (rest.isEmpty) {
    stderr.writeln('usage: wiring <file-substring>');
    exit(64);
  }
  final sub = rest.first;
  final matches =
      graph.nodes.where((n) => n.isFile && n.id.contains(sub)).toList();
  if (matches.isEmpty) {
    if (asJson) {
      stdout.writeln(
        jsonEncode({'verb': 'wiring', 'query': sub, 'results': []}),
      );
      return;
    }
    stdout.writeln('no file matches "$sub" — try `find $sub`');
    return;
  }
  if (matches.length > 1) {
    if (asJson) {
      stdout.writeln(
        jsonEncode({
          'verb': 'wiring',
          'query': sub,
          'ambiguous': matches.map((m) => m.id).toList(),
        }),
      );
      return;
    }
    stdout.writeln('multiple files match "$sub":');
    emit(matches.map((m) => '  ${m.id}').toList(), budget);
    return;
  }
  final id = matches.first.id;
  final record = _wiringRecord(graph, id);

  if (asJson) {
    // Shared remaining-count budget across sections, in their declared
    // order (declares, watches, reads, listens, navigates, navigates-to,
    // navigatesUnresolved, imports, imported-by) — total items across all
    // sections <= budget, not budget-per-section.
    final remaining = Budget(budget);
    final capped = <String, List<String>>{
      for (final key in [
        'declares',
        'watches',
        'reads',
        'listens',
        'navigates',
        'navigates-to',
        'navigatesUnresolved',
        'imports',
        'imported-by',
      ])
        key: remaining.take(record[key] ?? const []),
    };
    stdout.writeln(
      jsonEncode({
        'verb': 'wiring',
        'query': sub,
        'file': id.replaceFirst('file:', ''),
        'role': matches.first.role,
        ...capped,
        if (remaining.truncated) 'truncated': true,
      }),
    );
    return;
  }

  final out = <String>[
    '${id.replaceFirst('file:', '')}  [${matches.first.role}]',
  ];
  for (final label in ['declares', 'watches', 'reads', 'listens']) {
    final list = record[label]!;
    if (list.isEmpty) continue;
    out.add('$label (${list.length}):');
    out.addAll(list.map((e) => '  $e'));
  }
  final navLines = graph.navLines(id);
  if (navLines.isNotEmpty) {
    out.add('navigates (${navLines.length}):');
    out.addAll(navLines.map((l) => '  $l'));
  }
  for (final label in ['imports', 'imported-by']) {
    final list = record[label]!;
    if (list.isEmpty) continue;
    out.add('$label (${list.length}):');
    out.addAll(list.map((e) => '  $e'));
  }
  emit(out, budget, hint: 'raise --budget N');
}

void _impls(Graph graph, List<String> rest, int budget, bool asJson) {
  if (rest.isEmpty) {
    stderr.writeln('usage: impls <Type>');
    exit(64);
  }
  final type = rest.first;
  // TRANSITIVE subtype tree, not just direct children. `impls X` used to return
  // only one-level subtypes, so `impls BaseCachedResourceNotifier` showed just
  // `UserCachedResourceNotifier` and hid its 6 concrete leaves — false
  // completeness for "list every subclass" (found by an A/B eval). A
  // subtype-of-a-subtype is still a STATED fact (A extends B, B extends C ⇒ A is
  // a subtype of C), so the closure introduces no guessed edges. Cycle-guarded.

  // parent name -> its direct subtypes: (child name, declaring file), sorted.
  final childrenOf = <String, List<({String child, String file})>>{};
  for (final e in graph.edges) {
    if (e.rel != 'implements/extends') continue;
    final detail = e.detail ?? '';
    final arrow = detail.indexOf(' -> ');
    if (arrow < 0) continue;
    final child = detail.substring(0, arrow);
    final parent = detail.substring(arrow + 4);
    childrenOf
        .putIfAbsent(parent, () => [])
        .add((child: child, file: e.src.replaceFirst('file:', '')));
  }
  for (final list in childrenOf.values) {
    list.sort((a, b) => a.child.compareTo(b.child));
  }

  // BFS from `type` over the subtype relation, tracking depth for indentation.
  final rows = <({int depth, String child, String parent, String file})>[];
  final seen = <String>{type};
  final queue = <({String name, int depth})>[(name: type, depth: 0)];
  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    for (final kid in childrenOf[cur.name] ?? const []) {
      rows.add(
        (depth: cur.depth, child: kid.child, parent: cur.name, file: kid.file),
      );
      if (seen.add(kid.child)) {
        queue.add((name: kid.child, depth: cur.depth + 1));
      }
    }
  }

  // Test/integration fakes implementing any type in the resolved set. The
  // graph is lib-only, so a `_FakeRepo implements Repo` used only by tests is
  // invisible here — the blind spot that bites on an interface signature
  // change. Scanned on demand from the same test roots `callers` uses, and
  // kept in a separate section: a test fake is real for "what breaks if I
  // change this interface", but it is NOT a resolved lib graph edge.
  final testFakes = testSubtypesOf(seen);

  if (asJson) {
    stdout.writeln(
      jsonEncode({
        'verb': 'impls',
        'query': type,
        'results': rows
            .take(budget)
            .map((r) => {
                  'subtype': r.child,
                  'supertype': r.parent,
                  'depth': r.depth,
                  'file': r.file,
                })
            .toList(),
        'testSubtypes': testFakes
            .take(budget)
            .map((t) => {
                  'subtype': t.child,
                  'supertype': t.parent,
                  'relation': t.relation,
                  'file': t.file,
                  'line': t.line,
                })
            .toList(),
        if (rows.length > budget || testFakes.length > budget)
          'truncated': true,
      }),
    );
    return;
  }

  final out = <String>['implementers / subtypes of $type (transitive):'];
  if (rows.isEmpty && testFakes.isEmpty) {
    out.add('  (none found)');
  } else {
    for (final r in rows) {
      out.add('  ${'  ' * r.depth}${r.child} -> ${r.parent}  (${r.file})');
    }
    if (testFakes.isNotEmpty) {
      out.add('  test fakes (outside the graph, from test roots):');
      for (final t in testFakes) {
        out.add(
            '  ${t.child} ${t.relation} ${t.parent}  (${t.file}:${t.line})');
      }
    }
  }
  emit(out, budget, hint: 'raise --budget N');
}

/// One `find` hit: `kind` is the node kind (`file`/`provider`) or `symbol`
/// for a symbol-record match; `id` is the bare (unprefixed) name/path;
/// `inDeg` is the containing node's in-degree (0 when none).
class _FindHit {
  _FindHit(this.kind, this.id, this.inDeg, {this.line, this.role});
  final String kind;
  final String id;
  final int inDeg;
  final int? line;
  final String? role;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'id': id,
        if (line != null) 'line': line,
        'inDeg': inDeg,
      };
}

/// Splits [s] into lowercased tokens on `/`, `.`, `_`, and camelCase
/// boundaries — e.g. `lib/pin_unlock/PinUnlockService.dart` ->
/// {lib, pin, unlock, pinunlockservice, pin, unlock, service, dart} (the
/// full lowercased segment is kept alongside its camelCase split so
/// substring-style matches on a whole segment still work).
Set<String> _tokenize(String s) {
  final out = <String>{};
  for (final segment in s.split(RegExp(r'[/._]'))) {
    if (segment.isEmpty) continue;
    out.add(segment.toLowerCase());
    for (final camel in segment.split(RegExp(r'(?=[A-Z])'))) {
      if (camel.isEmpty) continue;
      out.add(camel.toLowerCase());
    }
  }
  return out;
}

/// True when every term in [terms] equals or is a prefix of some token in
/// [tokens] (case-insensitive; [terms] are pre-lowercased).
bool _matchesAllTerms(Set<String> tokens, List<String> terms) =>
    terms.every((t) => tokens.any((tok) => tok == t || tok.startsWith(t)));

void _find(Graph graph, List<String> rest, int budget, bool asJson) {
  if (rest.isEmpty) {
    stderr.writeln('usage: find <substr> [more terms]');
    exit(64);
  }
  // A single quoted arg with internal spaces ("delete device") carries the same
  // intent as separate args (delete device), but substring-matching the whole
  // spaced string — which never appears in an identifier — returned a false
  // "(no matches)" that reads as "this doesn't exist". Split on whitespace so a
  // natural-language phrase matches tokens the way the multi-arg form does.
  final parts = rest.length == 1
      ? rest.first.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList()
      : rest;
  if (parts.isEmpty) {
    stderr.writeln('usage: find <substr> [more terms]');
    exit(64);
  }
  final sub = parts.first.toLowerCase();
  final terms =
      parts.length > 1 ? parts.map((t) => t.toLowerCase()).toList() : null;
  final hits = <_FindHit>[];
  for (final n in graph.nodes) {
    final id = n.id;
    final bareName = bare(id);
    final nodeMatch = terms == null
        ? id.toLowerCase().contains(sub)
        : _matchesAllTerms(_tokenize(bareName), terms);
    if (nodeMatch) {
      hits.add(
        _FindHit(
          n.kind,
          bareName,
          graph.inDeg[id] ?? 0,
          role: n.isFile ? n.role : null,
        ),
      );
    }
    for (final s in n.symbols) {
      final name = s.name;
      final symMatch = terms == null
          ? name.toLowerCase().contains(sub)
          : _matchesAllTerms(
              {..._tokenize(bareName), ..._tokenize(name)}, terms);
      if (symMatch) {
        hits.add(
          _FindHit('symbol', '$name — $bareName', graph.inDeg[id] ?? 0,
              line: s.line),
        );
      }
      // Members (methods/getters/fields of a class/extension/mixin). Without
      // this, `find handleResume` / `find generateJwt` returned nothing even
      // though skeleton lists them — top-level names were indexed but members
      // weren't, forcing a grep fallback (surfaced by an A/B eval). Match the
      // member's DECLARED name only (not the whole signature, so parameter
      // types don't produce false hits).
      final memberEntries = s.memberIndex ?? s.members ?? const <String>[];
      for (final m in memberEntries) {
        final parsed = parseRenderedMember(m);
        if (parsed == null) continue;
        final mn = parsed.name;
        final memMatch = terms == null
            ? mn.toLowerCase().contains(sub)
            : _matchesAllTerms(
                {..._tokenize(bareName), ..._tokenize(mn)}, terms);
        if (memMatch) {
          hits.add(
            _FindHit('member', '$name.$mn — $bareName', graph.inDeg[id] ?? 0),
          );
        }
      }
    }
  }
  // Rank by in-degree of the containing node (desc), tie-break alphabetical.
  hits.sort((a, b) {
    final byDeg = b.inDeg.compareTo(a.inDeg);
    if (byDeg != 0) return byDeg;
    return a.id.compareTo(b.id);
  });

  if (asJson) {
    stdout.writeln(
      jsonEncode({
        'verb': 'find',
        'query': sub,
        'results': hits.take(budget).map((h) => h.toJson()).toList(),
        // Non-silent truncation, matching the other --json verbs (callers,
        // impls, …) — a consumer capping at --budget must know results dropped.
        if (hits.length > budget) 'truncated': hits.length - budget,
      }),
    );
    return;
  }

  String render(_FindHit h) {
    final line = h.line == null ? '' : ':${h.line}';
    final role = h.role == null ? '' : ' [${h.role}]';
    final suffix = h.inDeg > 0 ? ' ·${h.inDeg}⇐' : '';
    return '${h.kind}: ${h.id}$line$role$suffix';
  }

  final out = hits.map(render).toList();
  emit(
    out.isEmpty ? ['(no matches)'] : out,
    budget,
    hint: 'narrow the substring, or: sym <Name> for one symbol',
  );
}

/// One class/mixin/extension MEMBER whose declared name matched a `sym`/
/// `brief` query that had zero top-level symbol hits.
typedef MemberHit = ({
  String owner,
  String name,
  String file,
  int line,
  String sig
});

/// Case-insensitive exact-name search across every file's class/mixin/
/// extension members (mirrors `Graph.declarationsOf`'s iteration, but keeps
/// owner + signature instead of just the declaration site). Sorted by
/// file:line for determinism.
List<MemberHit> findMemberHits(Graph graph, String lower) {
  final hits = <MemberHit>[];
  for (final n in graph.nodes) {
    if (!n.isFile) continue;
    final file = bare(n.id);
    for (final s in n.symbols) {
      final memberEntries = s.memberIndex ?? s.members ?? const <String>[];
      for (final entry in memberEntries) {
        if (isMemberCapTrailer(entry)) continue;
        final parsed = parseRenderedMember(entry);
        if (parsed == null || parsed.name.toLowerCase() != lower) continue;
        final colon = entry.indexOf(': ');
        final sig = colon > 0 ? entry.substring(colon + 2) : entry;
        hits.add((
          owner: s.name,
          name: parsed.name,
          file: file,
          line: parsed.line,
          sig: sig,
        ));
      }
    }
  }
  hits.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });
  return hits;
}

/// `sym <Name>` — the symbol card: sig + doc + members + a peek at
/// imported-by, for one exact (case-insensitive) or substring-matched name.
void _sym(Graph graph, List<String> rest, int budget, bool asJson) {
  if (rest.isEmpty) {
    stderr.writeln('usage: sym <Name>');
    exit(64);
  }
  final query = rest.first;
  final lower = query.toLowerCase();

  // (file node, symbol record) pairs, case-insensitive exact match first;
  // substring fallback (capped at 5) only when there are zero exact hits.
  final exact = <(GraphNode, SymbolRec)>[];
  final substr = <(GraphNode, SymbolRec)>[];
  for (final n in graph.nodes) {
    if (!n.isFile) continue;
    for (final s in n.symbols) {
      final name = s.name;
      if (name.toLowerCase() == lower) {
        exact.add((n, s));
      } else if (name.toLowerCase().contains(lower)) {
        substr.add((n, s));
      }
    }
  }
  var matches = exact.isNotEmpty ? exact : substr;
  // Substring fallback is capped at 5; surface how many more were dropped so
  // the cap isn't silent (a `sym pin` with 12 hits used to look complete).
  var substrTruncated = 0;
  if (exact.isEmpty) {
    final sorted = matches.toList()
      ..sort((a, b) => a.$2.name.compareTo(b.$2.name));
    if (sorted.length > 5) substrTruncated = sorted.length - 5;
    matches = sorted.take(5).toList();
  }

  if (matches.isEmpty) {
    // No top-level symbol at all — fall back to class/mixin/extension
    // MEMBERS before giving up (`sym m13` used to fail even though the
    // method exists, because only top-level names were indexed here).
    final memberHits = findMemberHits(graph, lower);
    if (memberHits.isNotEmpty) {
      if (asJson) {
        stdout.writeln(
          jsonEncode({
            'verb': 'sym',
            'query': query,
            'results': memberHits
                .map((h) => {
                      'kind': 'member',
                      'owner': h.owner,
                      'name': h.name,
                      'file': h.file,
                      'line': h.line,
                      'sig': h.sig,
                    })
                .toList(),
          }),
        );
        return;
      }
      const cap = 10;
      final out = <String>[];
      for (final h in memberHits.take(cap)) {
        out.add('member: ${h.owner}.${h.name}  —  ${h.file}:${h.line}');
        out.add('  ${h.sig}');
      }
      if (memberHits.length > cap) {
        out.add('… ${memberHits.length - cap} more');
      }
      // ponytail: call-site count skipped (would need callers.dart's full
      // AST scan) — point at the verb that already does it instead.
      out.add('(run `callers $query` for call sites)');
      emit(out, budget);
      return;
    }
    if (asJson) {
      stdout.writeln(
        jsonEncode({'verb': 'sym', 'query': query, 'results': []}),
      );
      return;
    }
    stdout.writeln('no symbol matches "$query" — try `find $query`');
    return;
  }

  final records = matches.map((m) {
    final (file, s) = m;
    final fileId = file.id;
    final fileBare = bare(fileId);
    final importers = graph.edges
        .where((e) => e.dst == fileId && e.rel == 'imports')
        .map((e) => e.src.replaceFirst('file:', ''))
        .toList()
      ..sort();
    return {
      'name': s.name,
      'kind': s.kind,
      'file': fileBare,
      'line': s.line,
      'sig': s.sig,
      if (s.doc != null) 'doc': s.doc,
      if (s.members != null) 'members': s.members,
      'importedBy': importers,
    };
  }).toList();

  if (asJson) {
    stdout.writeln(
      jsonEncode({
        'verb': 'sym',
        'query': query,
        'results': records
            .map(
              (r) => {
                ...r,
                'importedBy': (r['importedBy']! as List).take(budget).toList(),
                // Full importer count, so the per-record `importedBy` cap at
                // --budget isn't silent.
                'importedByTotal': (r['importedBy']! as List).length,
              },
            )
            .toList(),
        if (substrTruncated > 0) 'truncated': substrTruncated,
      }),
    );
    return;
  }

  final out = <String>[];
  for (final r in records) {
    if (out.isNotEmpty) out.add('');
    out.add('${r['name']}  ${r['kind']}  ${r['file']}:${r['line']}');
    out.add('  ${r['sig']}');
    if (r['doc'] != null) out.add('  ${r['doc']}');
    final members = (r['members'] as List?)?.cast<String>();
    if (members != null && members.isNotEmpty) {
      out.add('  members:');
      out.addAll(members.map((m) => '    $m'));
    }
    final importedBy = (r['importedBy']! as List).cast<String>();
    if (importedBy.isNotEmpty) {
      final shown = importedBy.take(2).join(', ');
      final more =
          importedBy.length > 2 ? ', … ${importedBy.length - 2} more' : '';
      out.add('  imported-by (${importedBy.length}): $shown$more');
    }
  }
  if (substrTruncated > 0) {
    out.add('  (+$substrTruncated more substring matches — narrow the query)');
  }
  emit(out, budget, hint: 'raise --budget N');
}

/// Dead-code candidates. Caveats: only lib/+packages/ edges are known
/// (test-only usage, `ref.read` via overrides, codegen, and route targets can
/// be false positives), so treat output as a starting list to confirm, not a
/// delete list.
void _unused(Graph graph, List<String> rest, int budget) {
  final what = rest.isEmpty ? 'providers' : rest.first;
  final out = <String>[];
  if (what == 'providers' || what == 'all') {
    final dead = graph.unusedProviders
        .map(
          (n) => '  ${n.id.replaceFirst('provider:', '')}'
              ' — ${n.providerType} — ${n.declaredIn}${n.testOnlySuffix}',
        )
        .toList();
    out.add('providers with 0 lib consumers (${dead.length}):');
    out.addAll(dead.isEmpty ? ['  (none)'] : dead);
  }
  if (what == 'files' || what == 'all') {
    final orphans = graph.orphanFiles
        .map(
          (n) => '  ${n.id.replaceFirst('file:', '')}'
              '  [${n.role}]${n.testOnlySuffix}',
        )
        .toList();
    if (out.isNotEmpty) out.add('');
    out.add('files nothing imports (${orphans.length}):');
    out.addAll(orphans.isEmpty ? ['  (none)'] : orphans);
  }
  emit(out, budget);
}

/// Roles a file needs to have to count as a coverage gap in `untested files`
/// — the Standard-07-shaped set (view/controller/repository/provider); a
/// `misc`/`widget`/etc. file isn't expected to carry its own test file.
const _untestedRoles = {'view', 'controller', 'repository', 'provider'};

/// `untested` — coverage-gap surface built from Stage 1's `testRefs` counts.
/// Two sections, both sorted in-degree desc then name (same convention as
/// `unused`/`find`): providers with zero test references (candidate data —
/// a token-name match, not a resolved reference, see `GraphNode.testRefs`);
/// files with zero test references, filtered to the roles a change to them
/// is expected to need direct coverage for.
void _untested(Graph graph, int budget, bool asJson) {
  int inDeg(GraphNode n) => graph.inDeg[n.id] ?? 0;
  int Function(GraphNode, GraphNode) byDegThenName(
          String Function(GraphNode) key) =>
      (a, b) {
        final byDeg = inDeg(b).compareTo(inDeg(a));
        return byDeg != 0 ? byDeg : key(a).compareTo(key(b));
      };

  final providers = graph.nodes
      .where((n) => n.isProvider && n.testRefs == 0)
      .toList()
    ..sort(byDegThenName((n) => n.name!));

  final files = graph.nodes
      .where(
        (n) => n.isFile && n.testRefs == 0 && _untestedRoles.contains(n.role),
      )
      .toList()
    ..sort(byDegThenName((n) => n.id));

  if (asJson) {
    final remaining = Budget(budget);
    stdout.writeln(
      jsonEncode({
        'verb': 'untested',
        'providers': remaining.take(
          providers
              .map(
                (n) => {
                  'name': n.name,
                  'declaredIn': n.declaredIn,
                  'inDeg': inDeg(n),
                },
              )
              .toList(),
        ),
        'files': remaining.take(
          files
              .map(
                (n) => {
                  'file': n.id.replaceFirst('file:', ''),
                  'role': n.role,
                  'inDeg': inDeg(n),
                },
              )
              .toList(),
        ),
        if (remaining.truncated) 'truncated': true,
      }),
    );
    return;
  }

  String suffix(GraphNode n) => inDeg(n) > 0 ? ' ·${inDeg(n)}⇐' : '';
  final out = <String>[
    'providers with zero test references (${providers.length}):',
    ...providers.isEmpty
        ? ['  (none)']
        : providers.map(
            (n) => '  ${n.name} — ${n.providerType} — '
                '${n.declaredIn}${suffix(n)}',
          ),
    '',
    'files with zero test references (${files.length}):',
    ...files.isEmpty
        ? ['  (none)']
        : files.map(
            (n) =>
                '  ${n.id.replaceFirst('file:', '')}  [${n.role}]${suffix(n)}',
          ),
  ];
  emit(out, budget, hint: 'raise --budget N');
}

void _path(Graph graph, List<String> rest) {
  if (rest.length < 2) {
    stderr.writeln('usage: path <A> <B>');
    exit(64);
  }
  String? resolve(String s) {
    final hits = graph.nodes
        .where((n) => n.isFile && n.id.contains(s))
        .map((n) => n.id)
        .toList();
    if (hits.length == 1) return hits.first;
    final exact = hits.where((h) => h.endsWith('/$s') || h.endsWith(':$s'));
    if (exact.length == 1) return exact.first;
    if (hits.length > 1) {
      stdout.writeln('"$s" is ambiguous (${hits.length} files):');
      for (final h in hits.take(8)) {
        stdout.writeln('  ${h.replaceFirst('file:', '')}');
      }
    }
    return null;
  }

  final a = resolve(rest[0]);
  final b = resolve(rest[1]);
  if (a == null || b == null) {
    stdout.writeln(
      'could not resolve ${a == null ? rest[0] : rest[1]} to a single file'
      ' — try `find ${a == null ? rest[0] : rest[1]}`',
    );
    return;
  }
  // Undirected adjacency over imports + provider wiring (file<->provider<->file).
  final adj = <String, Set<String>>{};
  void link(String x, String y) {
    adj.putIfAbsent(x, () => {}).add(y);
    adj.putIfAbsent(y, () => {}).add(x);
  }

  for (final e in graph.edges) {
    final rel = e.rel;
    if (rel == 'imports' ||
        rel == 'declares' ||
        rel == 'reads' ||
        rel == 'watches' ||
        rel == 'listens' ||
        rel == 'navigates-to') {
      link(e.src, e.dst);
    }
  }
  // BFS
  final queue = <String>[a];
  final prev = <String, String?>{a: null};
  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    if (cur == b) break;
    for (final nb in adj[cur] ?? const <String>{}) {
      if (!prev.containsKey(nb)) {
        prev[nb] = cur;
        queue.add(nb);
      }
    }
  }
  if (!prev.containsKey(b)) {
    stdout.writeln('no path found between the two files');
    return;
  }
  final path = <String>[];
  String? cur = b;
  while (cur != null) {
    path.add(cur);
    cur = prev[cur];
  }
  stdout.writeln(
    path.reversed
        .map((n) => n.replaceFirst('file:', '').replaceFirst('provider:', 'Π '))
        .join('\n  → '),
  );
}
