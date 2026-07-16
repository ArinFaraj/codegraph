// Shared CLI plumbing for the query-side verbs (query.dart, brief.dart,
// diff.dart, impact.dart). One definition each of: the line-budgeted output
// contract, the shared-remaining-count JSON budget, the capped-join list
// renderer, and the in-degree "reader count" suffix — every verb printed
// these identically; this is the single copy.
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

void emit(List<String> lines, int budget, {String? hint}) {
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
