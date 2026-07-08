# codegraph benchmarks

Three harnesses:

| Harness | Command | Measures | Reproducible? |
|---------|---------|----------|---------------|
| **Usefulness** | `dart run benchmarks/usefulness/run.dart` | Regression gate: codegraph correctness vs **frozen** truth + the grep tool-call delta (test fixture) | Yes, deterministic, CI |
| **Performance** | `dart run benchmarks/perf.dart` | Build + query wall-clock ms | Yes, deterministic, CI |
| **Agent quality** | Workflow: `codegraph-benchmark.js` / `codegraph-benchmark-grep.js` | Sonnet agent + Opus judge on a private reference host — end-to-end answer quality | No: private host, LLM noise ±2 |

**Which to trust for which decision.** Usefulness/Performance are the CI gates —
they fail loudly on a real regression. Agent quality is the exploratory arm: run
it to find WHERE the tool helps or misleads a real agent, trust its specific
findings (exact missed/false files), not its aggregate score.

## Usefulness (`benchmarks/usefulness/`)

Deterministic comparison — no LLM judge. See [usefulness/README.md](usefulness/README.md).

## Performance (`benchmarks/perf.dart`)

See [perf_baseline.json](perf_baseline.json).

## Quality benchmark (`codegraph-benchmark.js`)

A repeatable, evidence-first benchmark that scores codegraph on the tasks an AI
agent actually uses it for — so tool-quality changes are **measured, not
asserted**. It is the harness that has driven the 0.8.x eval releases.

## What it does

`codegraph-benchmark.js` is a [Workflow](../plans/ROADMAP.md) script (uses
`agent()`/`pipeline()` — run it via the host's Workflow tool, not `node`). It:

1. Runs one **Sonnet agent per scenario** against a real host repo (a private
   reference monorepo), told to use codegraph as its primary tool.
2. Scores each answer with an **Opus judge** that establishes its OWN ground
   truth **without codegraph** (ripgrep + reads source + `dart analyze`) — the
   tool under test never defines the truth it is graded against, so a codegraph
   false edge the agent trusted is caught, not blessed. Grades 0-100 on four
   dimensions, returning a structured record:
   - **correctness** — 100 minus a heavy penalty per *verified* false claim.
   - **completeness** — fraction of ground-truth items/insights captured.
   - **calibration** — did stated confidence match reality? high+wrong = 0.
   - **efficiency** — tool-calls vs answer quality.
   - plus `overTrustedStructure` (did it assert a structural fact as a runtime
     answer, wrongly?) and the list of verified `falseClaims`.
3. Aggregates to an overall score (`0.35·correctness + 0.35·completeness +
   0.20·calibration + 0.10·efficiency`).

## The 8 scenarios (value-prop coverage)

`rel-auth` (relationship), `impact-i18n` (blast radius), `plan-feature`
(planning/blueprint), `hierarchy-cache` (transitive impls), `multipkg-button`
(lib↔packages boundary), `behav-staleprofile` + `behav-coldauth` (behavioral —
weighted 2× to test whether codegraph induces over-confidence on runtime
questions), `refactor-rename` (completeness incl. notifier subclasses).

## How to run

Invoke the Workflow tool with
`{ scriptPath: "benchmarks/codegraph-benchmark.js" }` from the reference host's
working directory, with the codegraph binary you want to test installed
(`dart pub global activate -sgit … && codegraph build` first). It returns
`{ summary, results }`.

## Baseline (v0.8.4, private reference host)

overall **91** · correctness 91 · completeness 94 · calibration 85 ·
efficiency 88 · overTrustedStructure 1/8.

Two findings drove v0.8.5:
- It **debunked** a hypothesized fix: the "over-confidence on behavioral
  questions" worry was not systematic — both behavioral scenarios scored 94-95.
- It **pinpointed** the real gap: `rel-auth` completeness **71**, because
  `readers` missed bare `read/watch/listen(provider)` calls inside
  `extension on Ref` bodies (fixed in 0.8.5).

### Delta after v0.8.5 + v0.8.6 (reader-detection fixes)

The benchmark's own weakest scenario (`rel-auth` completeness 71) drove two
fixes: detect bare `read/watch/listen(provider)` inside `extension on Ref`
(0.8.5) and `ProviderContainer.read` (0.8.6). Measured DETERMINISTICALLY (the
aggregate judge score wobbles ±2 within agent/judge noise, so the reliable
signal is the verb output, not the score): `readers authTokenProvider` went
**18-19 → 28** (grep ground truth ≈27) — the completeness gap is essentially
closed. All three originally-missed high-value readers (a Ref extension, a
dialog helper, and a key-prompt extension) are now caught, zero garbage
(≥511/513 reads resolve to a declared provider). Residual: cascade
`ref..listen(provider)` forms (documented in CHANGELOG 0.8.6).

**Lesson:** trust the judge's specific, reproducible findings (exact missed
files) over its aggregate 0-100 score. Re-run after any tool change and record
the delta here.

## Performance benchmark (`perf.dart`)

Measures median wall time (ms) over 5 iterations on the **same fixture** as
`test/fixture.dart`:

- `codegraph build`
- `find home`, `sym HomePage`, `readers homeProvider`, `impls Shape`
- `callers pingTarget`, `callchain chainEntry --depth 3`

```bash
# Capture / refresh baseline after a deliberate perf change:
dart run benchmarks/perf.dart --write-baseline

# Compare current code against committed baseline (fails on >15% regression
# unless within 25ms noise floor):
dart run benchmarks/perf.dart --compare benchmarks/perf_baseline.json
```

CI runs the compare step after `dart test` on every push/PR.

### Grep control arm

`codegraph-benchmark-grep.js` — same scenario set (+ 5 micro-scenarios), but the
agent is forbidden from using codegraph. Run both workflows from the reference
host and compare `summary.overall` / per-scenario completeness.

Shared scenarios: `codegraph-benchmark-scenarios.js`.
