# codegraph roadmap

Execution-ready plans for the next three releases. Each plan file follows the
format the staged-agent pipeline consumes (hard constraints, wire-format pins,
stages with refusal gates and acceptance criteria). Pick a file, run the
pipeline: plan → staged cheap agents with independent gates between stages →
fresh-eyes adversarial review → fix round → release → host rollout.

| Release | Theme | File | Size |
|---|---|---|---|
| 0.6.0 | **Trust** — close the gaps that make agents hedge | [0.6.0-trust.md](0.6.0-trust.md) | ~4 stages |
| 0.7.0 | **Lint** — the graph becomes prescriptive | [0.7.0-lint.md](0.7.0-lint.md) | ~4 stages |
| 0.8.0 | **Leverage** — CI test selection, risk score, Riverpod rules | [0.8.0-leverage.md](0.8.0-leverage.md) | ~4 stages |

## Why this order

0.6.0 first because both later releases *depend on its precision*: `lint`
needs `line` on import edges (0.6) for usable output, and `affected-tests`
must never skip a test because of a token-match false negative — it needs the
registry-resolved testRefs (0.6). 0.7.0 before 0.8.0 because the risk score
consumes lint's new-violation count, and because lint is the single
highest-leverage feature for the actual daily workflow (an AI-developed repo
whose agents drift from the standards nobody enforces).

## Standing doctrine (applies to every plan; do not re-derive)

1. Syntax-only parsing; no pub get in the host. Ever.
2. Everything `build` writes under `docs/maps/` is deterministic
   (byte-identical for identical source). `docs/maps/notes/` is the one
   ungated dir. Git/wall-clock allowed in VERB output only.
3. NEVER-GUESS: a wrong edge/violation/skip is a blocker; a missing one is
   fine. Every resolution or selection mechanism ships with an explicit
   refusal gate AND a test proving the refusal. For CI-affecting features
   (affected-tests) the doctrine inverts to FAIL-OPEN: when uncertain, run
   MORE tests, never fewer.
4. Wire-format changes are ADDITIVE with pinned key positions, stated in the
   plan before implementation.
5. Query output is line-budgeted; `--json` caps TOTALS with `truncated`.
6. Agents implement stages INCREMENTALLY (land + verify one mechanism before
   the next) — an API death mid-flight must leave a green prefix, not a
   fragment. (Learned 0.5.0: the all-at-once attempt died broken; the
   incremental retry died green.)
7. Gates between stages are run independently by the orchestrator:
   `dart analyze --fatal-infos && dart format --set-exit-if-changed . &&
   dart test && dart test`, plus byte-stability on a reference host where the
   plan demands it.

## Rejected / deferred — do not re-propose without a new trigger

(Consolidated from CHANGELOG; the authoritative list lives there.)
- MCP server mode (resident schema tokens dwarf CLI call cost).
- LLM output in generated artifacts; git-churn counts in committed artifacts
  (both break `check()` determinism).
- Per-edit (PostToolUse) regen; 2k-token session injection (passport covers).
- PageRank `map` verb, fold/preview levels, `slice`, BM25 `locate`,
  embedding search — all gated on evidence of need that hasn't appeared.
- Framework extractors beyond Riverpod + GoRouter — explicit user decision;
  0.6.0 instead makes the README honest about it.
- YAML config — `codegraph.json` chosen (stdlib jsonDecode, zero new deps;
  yaml is only a transitive dep and depending on transitives directly is the
  mistake the analyzer dep already corrected once).

## Not scheduled, kept visible

- Markdown-writer extraction from engine.dart (~360 lines → markdown.dart):
  clean cohesion win, no urgency. Fold into whichever release next touches
  the writer substantially (0.6.0 Stage 2 does — see that plan).
- `passport`/hook UserPromptSubmit per-task packs: still deferred on noise
  risk.
- Windows PowerShell hook: gap, not rejection.
