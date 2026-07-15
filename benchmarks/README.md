# codegraph benchmarks

Four harnesses; the first two are CI gates in this repo, the last two live in
the private reference host repo (they necessarily name private symbols, which
the docs-hygiene doctrine keeps out of this public tree).

| Harness | Where | Command | Measures | Gate? |
|---------|-------|---------|----------|-------|
| **Usefulness** | here | `dart run benchmarks/usefulness/run.dart --check` | recall/precision vs frozen truth on the synthetic fixture, + grep A/B | CI, fails on any per-scenario drop below `usefulness/baseline.json` |
| **Performance** | here | `dart run benchmarks/perf.dart --compare benchmarks/perf_baseline.json` | build + query wall-clock | CI, fails on >15% regression |
| **Real-repo suite** | reference host, `tools/codegraph_bench/run.dart` | run from the host repo | 12 invariant checks on the real monorepo, each guarding a specific historical bug (hand-verified rg truth, never graph-derived) | local gate - run before every release |
| **Agent quality** | reference host, `tools/codegraph_bench/*.js` | Workflow tool from the host repo | Sonnet agent + judge A/B (codegraph arm vs grep arm) on end-to-end answer quality | exploratory only |

## Which to trust for which decision

Usefulness + Performance fail loudly in CI on a real regression. The
real-repo suite catches what a 143-file fixture structurally cannot: package
discovery at monorepo scale, barrel/export closures, real Riverpod usage
diversity, name-collision refusal at scale. The agent-quality harness answers
exactly one question the deterministic suites cannot: does the tool make a
real agent's final answer better, and does it stay CALIBRATED on behavioral
questions where structure and runtime truth diverge? Trust its specific
findings (exact missed files, verified false claims), never its aggregate
score - expect several points of run-to-run noise at n=1 per scenario.

## Honesty rules (apply to every harness)

1. Ground truth is NEVER derived from codegraph's own output. Fixture truth
   is frozen literals in `usefulness/scenarios.dart`; real-repo truth is
   hand-verified rg recipes frozen at a pinned host commit; agent-quality
   judges must establish truth without running codegraph, for BOTH arms.
2. Prefer scenarios that can FAIL: false-positive guards and wrong-edge
   refusals, not just recall. Wrong edges are blockers (the tool's own
   doctrine), so the benchmark's first job is catching wrong edges.
3. Both arms of any A/B run the same scenario set under the same judge
   standard, or their scores are not comparable.
4. Aggregates are computed in code, never by an LLM judge.
5. A known engine gap is an `xfail` check, not an undocumented hole - when it
   starts passing, it is promoted in the engine-fix commit.

## History note (2026-07-10 overhaul)

Benchmark results produced before 2026-07-10 are not comparable to current
ones. The old setup had: a usefulness harness that was never wired into CI
and could not fail; a grep arm whose impact recipe could never match a
`package:` import (its biggest "codegraph win" was a harness bug); an
output-size metric that always read 1 for codegraph (single-line JSON); an
ambiguity-refusal scenario that tested an in-memory flag the shipped CLI
never exposed; and an agent-quality harness whose ground-truth guidance told
the judge to run codegraph (circular), with arms on different scenario sets,
judge-computed arithmetic, and pseudonymized symbol names that made the
committed scenarios unrunnable against the actual host.

## Usefulness (`benchmarks/usefulness/`)

Deterministic, no LLM. See [usefulness/README.md](usefulness/README.md).
Update floors only after a deliberate change:
`dart run benchmarks/usefulness/run.dart --write-baseline` (say why in the
commit).

## Performance (`benchmarks/perf.dart`)

Median wall time over 5 iterations on the same fixture as `test/fixture.dart`.
Baseline: [perf_baseline.json](perf_baseline.json);
`--write-baseline` to refresh after a deliberate perf change.
