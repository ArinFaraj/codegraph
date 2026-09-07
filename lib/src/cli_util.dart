// Shared CLI plumbing for the query-side verbs (query.dart, brief.dart,
// diff.dart, impact.dart). One definition each of: the line-budgeted output
// contract, the shared-remaining-count JSON budget, the capped-join list
// renderer, and the in-degree "reader count" suffix — every verb printed
// these identically; this is the single copy.
import 'dart:convert';
import 'dart:io';

import 'freshness.dart' show freshnessChecked, lastLoadFresh;

int? intFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return int.tryParse(args[i + 1]);
  return null;
}

/// Returns command/operand arguments while removing flags AND the values of
/// known value-taking flags.
///
/// A plain `where(!startsWith('--'))` leaves `20` from `--budget 20` behind as
/// an operand. That is mostly harmless for single-argument verbs, but turns a
/// multi-term query such as `find vault --budget 20` into `find vault 20` and
/// produces a false empty result. Keep this shared so every CLI parser makes
/// the same distinction.
List<String> positionalArgs(
  List<String> args, {
  Set<String> valueFlags = const {'--budget', '--depth', '--base'},
}) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      out.add(arg);
      continue;
    }
    if (valueFlags.contains(arg) && i + 1 < args.length) i++;
  }
  return out;
}

/// Approximate token count for [s], the same chars/4 estimate `INDEX.md`'s
/// token column already uses. Deliberately the cheap estimate: a real BPE
/// count would need a vendored tokenizer per model and would still be wrong
/// for the next one.
int estTokens(String s) => (s.length / 4).ceil();

void emit(
  List<String> lines,
  int budget, {
  String? hint,
  bool cost = true,
  List<String> footers = const [],
}) {
  final written = <String>[];
  for (final l in lines.take(budget)) {
    written.add(l);
  }
  if (lines.length > budget) {
    written.add('… ${lines.length - budget} more (raise --budget to see all)');
    if (hint != null) written.add('  ($hint)');
  }
  // Footers sit outside --budget for the same reason the caveat does:
  // disclosure that a small budget can silence is disclosure that fails
  // exactly when the caller is least able to afford being misled.
  written.addAll(footers);
  for (final l in written) {
    stdout.writeln(l);
  }
  // Counts what emit wrote, not the caveat line that follows it: the caveat
  // is fixed per verb and an agent budgeting a call cares about the answer.
  if (cost && written.isNotEmpty) {
    stdout.writeln('cost: ~${estTokens(written.join('\n'))} tok');
  }
}

/// Prints [record] as the `--json` answer with `estTokens` attached: what this
/// record costs the caller to read, in the record itself, so an agent can
/// budget the next call instead of discovering the size after paying for it.
///
/// The count includes its own digits ([_settleEstTokens] iterates to a fixed
/// point), so it describes the string actually printed rather than a
/// pre-insertion payload that no one receives.
void emitJson(Map<String, dynamic> record) {
  stdout
      .writeln(jsonEncode({...record, 'estTokens': _settleEstTokens(record)}));
}

int _settleEstTokens(Map<String, dynamic> record) {
  var tokens = 0;
  for (var i = 0; i < 5; i++) {
    final next = estTokens(jsonEncode({...record, 'estTokens': tokens}));
    if (next == tokens) break;
    tokens = next;
  }
  return tokens;
}

/// How separated the top of a ranked answer is from the rest, under the
/// ranking that was actually used.
///
/// This grades the RANKING, never the answer: `high` means one hit stands
/// clear of the next, not that it is the right one. The case worth naming is
/// the flat one - when N hits tie at the top the list is arbitrary past that
/// point, and an answer that reports `low` gets read as a starting point
/// instead of a verdict. [decisiveTop] is for a different lane entirely (an
/// exact, unique name match), where in-degree separation says nothing.
({String confidence, int marginPct, int tiedAtTop}) rankConfidence(
  List<int> scoresDesc, {
  bool decisiveTop = false,
}) {
  if (scoresDesc.isEmpty) {
    return (confidence: 'low', marginPct: 0, tiedAtTop: 0);
  }
  if (decisiveTop || scoresDesc.length == 1) {
    return (confidence: 'high', marginPct: 100, tiedAtTop: 1);
  }
  final top = scoresDesc.first;
  var tied = 1;
  while (tied < scoresDesc.length && scoresDesc[tied] == top) {
    tied++;
  }
  if (tied > 1) return (confidence: 'low', marginPct: 0, tiedAtTop: tied);
  final margin = ((top - scoresDesc[1]) / top * 100).round();
  final confidence = margin >= 50
      ? 'high'
      : margin >= 20
          ? 'medium'
          : 'low';
  return (confidence: confidence, marginPct: margin, tiedAtTop: 1);
}

/// The text-mode footer for [rankConfidence], naming the tie when there is
/// one so the number is readable without the JSON.
String confidenceFooter(({String confidence, int marginPct, int tiedAtTop}) r) {
  if (r.tiedAtTop > 1) {
    return 'confidence: ${r.confidence} - ${r.tiedAtTop} hits tied at the '
        'top, order past them is arbitrary';
  }
  return 'confidence: ${r.confidence} (margin ${r.marginPct}%)';
}

/// Joins [items] capped at 10 + a `", … N more"` trailer — every file/provider
/// list line in a brief/diff card must stay short even when the underlying
/// list is 100+ items.
String joinCapped(List<String> items) {
  final shown = items.take(10).join(', ');
  final more = items.length > 10 ? ', … ${items.length - 10} more' : '';
  return '$shown$more';
}

/// `n > 0 ? ' ·N⇐' : ''` — the in-degree "reader count" suffix appended to a
/// file/provider line across brief/diff/impact.
String inDegSuffix(int n) => n > 0 ? ' ·$n⇐' : '';

/// Strips a node id's `kind:` prefix (`file:lib/x.dart` -> `lib/x.dart`,
/// `provider:name` -> `name`) — every verb that prints a bare id needed this.
String bare(String id) => id.substring(id.indexOf(':') + 1);

/// Runs `git <args>` via `Process.runSync`, returning `null` (never
/// throwing) when git isn't on PATH (`ProcessException`) — the guard every
/// direct git call in this codebase must use, so a missing git binary
/// degrades a feature instead of crashing the whole command.
ProcessResult? runGit(List<String> args, {String? workingDirectory}) {
  try {
    return Process.runSync('git', args, workingDirectory: workingDirectory);
  } on ProcessException {
    return null;
  }
}

/// Recent-edit count per path, over the last [days] of history, keyed the way
/// the graph keys files (relative to the working directory, via `--relative`,
/// so a package nested inside a larger repo still matches).
///
/// Verb output only. Doctrine 2 keeps churn out of anything `build` writes
/// because the number moves as its window slides, which would break the
/// byte-identical `check()` gate; a verb has no such contract and this is
/// where the signal is worth having - it is the difference between "47 files
/// depend on this" and "47 files depend on this, and it was edited 128 times
/// this quarter."
///
/// Empty when git is missing, this is not a repository, or nothing was
/// touched. Churn annotates, never gates, so absence must degrade the line
/// instead of failing the verb.
///
/// `--no-renames` is a cost decision with a stated consequence: a file's
/// churn starts over when it moves. Rename detection tripled this call on a
/// 2,829-commit host (0.16s vs 0.05s) and git abandons it there anyway
/// ("exhaustive rename detection was skipped"), so the accurate-looking option
/// is the one that is both slower and inconsistent between repositories.
/// Counting commits that named this exact path is cheap, deterministic, and
/// says what it means.
Map<String, int> churnByPath({int days = 90}) {
  final result = runGit([
    'log',
    '--since=$days.days',
    '--name-only',
    '--relative',
    '--no-renames',
    '--pretty=format:',
  ]);
  if (result == null || result.exitCode != 0) return const {};
  final counts = <String, int>{};
  for (final line in (result.stdout as String).split('\n')) {
    final path = line.trim();
    if (path.isEmpty) continue;
    counts[path] = (counts[path] ?? 0) + 1;
  }
  return counts;
}

/// `' ~N'` for a path with recent edits, empty otherwise - the churn suffix
/// on a file line across impact/change/review.
String churnSuffix(Map<String, int> churn, String path) {
  final n = churn[path];
  return n == null || n == 0 ? '' : ' ~$n';
}

/// The freshness clause every typed empty result carries, so an agent can
/// never mistake "not in the graph" for "graph predates the code" - the
/// documented silent-false-negative trap. loadFresh guarantees fresh unless
/// --no-rebuild kept a stale graph, which this then flags loudly.
String freshnessClause(int files) => !freshnessChecked
    ? 'freshness unchecked (--no-rebuild), $files files indexed'
    : lastLoadFresh
        ? 'graph fresh, $files files indexed'
        : 'GRAPH STALE - run: codegraph build';

/// One-line scope caveat per verb, printed at the end of every text answer
/// and carried as `caveats` in --json. One registry so the wording cannot
/// drift per verb: LIMITATIONS.md is the long-form registry, this is the line
/// that prevents over-trust at the moment of use.
const verbCaveats = <String, List<String>>{
  'readers': [
    'reader edges are file-level and lib-only; typed wrapper-held refs are '
        'detected in resolved builds but may be missed by syntax fallback',
    'ProviderScope overrides are not modeled - which implementation actually '
        'executes may differ per scope (bootstrap/test/route overrides)',
    'family providers collapse to one node - userProvider(a) and '
        'userProvider(b) are the same reader edge',
  ],
  'provider': [
    'reader edges are file-level and lib-only; typed wrapper-held refs are '
        'detected in resolved builds but may be missed by syntax fallback',
    'ProviderScope overrides are not modeled - which implementation actually '
        'executes may differ per scope (bootstrap/test/route overrides)',
    'family providers collapse to one node - userProvider(a) and '
        'userProvider(b) are the same reader edge',
  ],
  'wiring': [
    'lib-only; navigation targets are captured expressions, not a route graph'
  ],
  'route': [
    'resolved typed go_router annotations only; raw GoRoute trees, global '
        'redirects, dynamic navigation, and generated-only behavior are not '
        'modeled',
    'paths are patterns, not runtime locations; relative routes may have '
        'multiple placements and navigators',
  ],
  'impls': [
    'stated extends/implements only; "test fakes" entries are scanned from '
        'test roots, outside the lib graph'
  ],
  'find': ['indexes lib + local packages only (no test/, no generated files)'],
  'sym': ['imported-by lists lib importers only (tests excluded)'],
  'callers': [
    'AST call sites; dynamic dispatch/reflection is invisible',
    'syntax mode merges same-named declarations; --resolved attributes each '
        'site to its analyzer target',
  ],
  'refs': [
    'AST references; dynamic dispatch/reflection is invisible',
    'syntax mode merges same-named declarations; --resolved attributes each '
        'site to its analyzer target',
  ],
  'impact': [
    'follows imports, Riverpod readers, and resolved typed-route topology; '
        'runtime DI, dynamic dispatch, and string-computed routes are not included'
  ],
  'affected-tests': [
    'targeted plans are advisory until the mutation oracle proves zero omitted '
        'failing suites; uncertainty expands to package/workspace commands',
    'static imports, provider interactions, test helpers, and parts cannot see '
        'every runtime, platform, service-locator, or generated edge',
  ],
  'trace': [
    'frames resolve by URI and declared name; a closure, a generated shim or '
        'an inlined frame can name a symbol with no declaration in the graph, '
        'and shows without a decl line rather than being dropped',
    'external frames (SDK, pub dependencies) are marked, not resolved - the '
        'graph indexes lib + local packages only',
  ],
  'unused': [
    'CANDIDATES, not verdicts - confirm with exact-path grep across lib test '
        'integration_test patrol_test, then flutter analyze'
  ],
  'untested': [
    'token/import matching - candidate data; barrel credit follows the '
        'export closure',
    'a name declared in several files shares one credit - an untested '
        'same-named declaration can inherit a tested one\'s credit',
  ],
};

/// Which low-level verbs each intent verb composes - its caveat list is the
/// deduped union of theirs ([caveatsFor]), computed at runtime so the wording
/// can never drift from the constituent entries above. 'review' shares
/// diff's (none today) and 'plan' shares blueprint's (none), so neither
/// needs an entry.
const _intentConstituents = <String, List<String>>{
  'uses': ['readers', 'impls', 'callers', 'refs', 'wiring'],
  'change': ['impact', 'impls', 'untested'],
  'health': ['unused', 'untested'],
};

/// Caveat list for [verb]: the registry entry, or for an intent verb the
/// deduped union of its constituents' entries (order-preserving).
List<String> caveatsFor(String verb) {
  final parts = _intentConstituents[verb];
  if (parts == null) return verbCaveats[verb] ?? const [];
  final out = <String>[];
  for (final p in parts) {
    for (final c in verbCaveats[p] ?? const <String>[]) {
      if (!out.contains(c)) out.add(c);
    }
  }
  return out;
}

/// Text-mode caveat trailer. No-op for verbs with nothing to disclaim.
void emitCaveats(String verb) {
  final c = caveatsFor(verb);
  if (c.isNotEmpty) stdout.writeln('caveat: ${c.join('; ')}');
}

/// The shared --json header keys: verb, query, graph freshness, and the same
/// caveats the text form prints. Spread FIRST so existing keys stay in place.
Map<String, dynamic> envelope(String verb, String query) => {
      'verb': verb,
      'query': query,
      // null = freshness unchecked (--no-rebuild skipped the digest walk).
      'fresh': freshnessChecked ? lastLoadFresh : null,
      'caveats': caveatsFor(verb),
    };

/// Shared remaining-count budget threaded through the ordered sections of a
/// `--json` record so the TOTAL items emitted across every section is capped
/// at the original `--budget`, not `budget` per section. [truncated] is set
/// once any section is cut short.
class Budget {
  Budget(this.remaining);
  int remaining;
  bool truncated = false;

  List<T> take<T>(List<T> items) {
    if (items.length > remaining) truncated = true;
    final taken = items.take(remaining).toList();
    remaining -= taken.length;
    return taken;
  }
}
