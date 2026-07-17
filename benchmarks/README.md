# codegraph benchmarks

The benchmark suite is public, deterministic, and runnable from this repo.
Ground truth lives in generated or synthetic fixtures so results can be
reproduced without access to any external codebase.

| Harness | Where | Command | Measures | Gate? |
|---------|-------|---------|----------|-------|
| **Usefulness** | here | `dart run benchmarks/usefulness/run.dart --check` | recall/precision vs frozen truth on the synthetic fixture, + grep A/B | CI, fails on any per-scenario drop below `usefulness/baseline.json` |
| **Performance** | here | `dart run benchmarks/perf.dart --compare benchmarks/perf_baseline.json` | syntax/resolved build, graph queries, indexed vs analyzer rename and callers | CI, fails on >15% regression outside the noise floor |
| **Affected tests** | here | `dart run benchmarks/affected_tests.dart` | exact file/symbol-selected entrypoints and fail-open expansion vs frozen handwritten truth | CI, zero omissions or set mismatches allowed |
| **Route mutations** | here | `dart run benchmarks/route_mutations.dart` | applies a real typed-route page mutation, executes the full test universe, and compares discovered failures with the selected plan | CI, zero omitted failing tests and zero exact-set mismatches |
| **Agent impact** | here, `agent_impact/` | `dart run benchmarks/agent_impact/runner.dart --agent devin` | the NORTH-STAR metric (doctrine 8): with-vs-without codegraph agent A/B on 4 edit + 4 must-refuse tasks, scored by frozen code-computed oracles | harness self-checks in CI (`test/agent_impact_test.dart`); agent runs are local/on-demand |

## Which to trust for which decision

Usefulness catches wrong or missing answers; Performance catches latency
regressions. Affected tests uses an asymmetric frozen-set oracle: any omitted
required entrypoint fails, and uncertainty cases must expand to the complete
runnable suite. Route mutations is the stronger executable safety oracle: it
starts green, changes real source, runs every test to discover failures, and
then requires every failing test to be selected. The current corpus establishes
that machinery with typed route/page/caller propagation; expand it for route
moves, redirect replacement, and navigator reassignment before treating
targeted plans as authoritative. The frozen-set suite includes a same-file
symbol-body case where the changed
function's tests must be selected and a sibling function's test must not. The
frozen framework cases also require real Riverpod invalidate/refresh, nested
raw GoRouter navigation, and resolved typed-route navigation-to-page edges,
plus exact Flutter/Dart commands across a local package boundary. The
refactor portion deliberately compares the persistent index
with the previous query-time analyzer path on the same semantic task. Tests
separately lock the safety invariants: unrelated same-named methods stay
untouched, override sets move together, test references are included, and
external contracts or ambiguous targets are refused.

## Honesty rules (apply to every harness)

1. Ground truth is NEVER derived from codegraph's own output. Fixture truth
   is frozen literals in `usefulness/scenarios.dart` and test expectations.
2. Prefer scenarios that can FAIL: false-positive guards and wrong-edge
   refusals, not just recall. Wrong edges are blockers (the tool's own
   doctrine), so the benchmark's first job is catching wrong edges.
3. Both arms of any A/B run the same generated project and semantic task.
4. Aggregates are computed in code, never by an LLM judge.
5. A known engine gap is an `xfail` check, not an undocumented hole - when it
   starts passing, it is promoted in the engine-fix commit.
6. A selection benchmark may claim zero unsafe misses only when it executes
   the mutated program's complete test universe; set-only oracles must say so.

## Comparability note

Baseline numbers are meaningful only on comparable hardware and SDK versions.
CI uses them as a regression tripwire with both a percentage threshold and an
absolute noise floor; use the indexed-vs-analyzer ratio for the most portable
view of the refactor improvement.

## Usefulness (`benchmarks/usefulness/`)

Deterministic, no LLM. See [usefulness/README.md](usefulness/README.md).
Update floors only after a deliberate change:
`dart run benchmarks/usefulness/run.dart --write-baseline` (say why in the
commit).

## Performance (`benchmarks/perf.dart`)

Median wall time over 5 iterations on the same fixture as `test/fixture.dart`.
Resolved builds and analyzer-backed renames use 3 iterations because they are
the expensive baseline. `rename_indexed_ms` and `rename_analyzer_ms` execute
the same qualified rename as a dry run; only where the semantic work happens
differs. The harness also requires indexed rename to remain at least 5x faster
than fresh query-time analysis. The same paired measurement and 5x floor apply
to `callers --resolved`.
Baseline: [perf_baseline.json](perf_baseline.json);
`--write-baseline` to refresh after a deliberate perf change.
