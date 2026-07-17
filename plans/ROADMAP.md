# codegraph roadmap

The active direction is v3: codegraph is moving from a read-only better-grep
to a resolved knowledge-and-action system that helps an agent change code
without breaking it. [`BRD-actuator.md`](BRD-actuator.md) is the north star;
[`knowledge-model.md`](knowledge-model.md) defines the layered graph behind it.

## Current state

| Milestone | Status | Plan | Outcome |
|---|---|---|---|
| 3.0 **Resolved core** | Shipped in v3.0.0 | [3.0-resolved-core.md](3.0-resolved-core.md) | Resolved builds by default, confidence provenance, element-precise callers/refs |
| 3.1 **Rename actuator MVP** | Shipped in v3.0.0 | [3.1-actuator-rename.md](3.1-actuator-rename.md) | Dry-run/apply renames with whole-hierarchy support and strict refusal gates |
| 3.2 **Persistent semantic index** | Implemented (incl. cancellation + Stage A harness) | [3.2-agent-impact-and-resolved-session.md](3.2-agent-impact-and-resolved-session.md) | Graph-speed semantic operations; prevalidated, rollback-backed, cancellable rename apply; the agent-impact benchmark harness |
| 3.3 **Typed route topology** | Implemented | this roadmap + changelog | Resolved annotation trees, reusable placements, paths, shells/branches, navigators, redirects, route query, and impact edges |

The old retrieval usefulness and performance suites remain regression gates.
They are no longer the definition of product success.

## What comes next

The execution sequence continues the safety work started in
[3.2 — agent impact and resolved session](3.2-agent-impact-and-resolved-session.md).

1. **Complete the affected-test mutation matrix.** The file-level planner,
   test-helper/part ownership, package/runner grouping, complete JSON contract,
   fail-open expansions, first frozen CI oracle, and conservative resolved
   changed-symbol/hunk attribution are implemented. The first real executable
   mutation now proves page → route → typed caller propagation. Next add old+new
   topology unions for route moves/removals, redirect replacement, and
   navigator reassignment. Preserve a baseline graph, diff stable topology
   facts rather than offset-based occurrence ids, seed both endpoints of every
   removed or added relation, traverse both snapshots, and add a stable
   `uses-navigator` fact. Exact topology attribution may replace generic file
   fallback only for the classified hunk; any unclassified hunk must expand.
   Then expand the full Flutter/Riverpod/GoRouter mutation matrix and every
   fallback boundary. Keep
   `safeToSkipUnselected: false` until that matrix proves zero omitted suites.
2. **Cover raw GoRouter topology and close navigation-resolution gaps.** A
   1,520-file validation host contained 74 raw `GoRoute` constructors, two
   shell constructors, 13 route redirects, zero typed-route contracts, and
   only 39 of 99 navigation calls resolved. Extend the occurrence-based route
   index to exact, statically constructed `GoRoute`, `ShellRoute`, and
   `StatefulShellRoute` trees; join names, paths, pages, redirects, navigator
   ownership, and branch ancestry; then resolve the remaining exact navigation
   expression shapes. Refuse dynamic `RoutingConfig`, computed route lists,
   runtime redirects, and ambiguous names rather than inventing topology.
3. **Model Riverpod runtime scope contracts.** Official Riverpod scoping uses
   `dependencies`, `ProviderScope`/`ProviderContainer` overrides, and
   `@Dependencies` on consumers. Extract exact override sites, scoped-provider
   dependencies, family-instance keys where static, and scope ancestry so an
   agent can ask which implementation executes in each subtree. Preserve a
   resolved-only refusal boundary for dynamic override lists and runtime scope
   construction.
4. **[Done 2026-07-17] Operation cancellation.** Ctrl-C is honored at safe
   checkpoints only (exit 130, tree untouched); the install/rollback critical
   section is structurally uninterruptible and a too-late cancel is disclosed
   (`lateCancel`). lib/src/cancellation.dart + test/cancellation_test.dart.
5. **Deepen P1 conformance.** Turn `lint` into persistent CI value with
   repository-specific layering, pairing, and must-stay-in-sync invariants.
   Prefer rules proven by reproducible failures over a large generic catalog.
6. **Expand P2 only after the benchmark proves the thesis.** Signature-change edit
   sets and cross-package public-API safety are the next actuator frontier.
   Every edit remains apply-ready, reversible, and refusal-gated.
7. **Consider P3 data flow later.** Lifecycle and value-flow analysis begins
   only after the actuator shows a large, repeatable agent-quality delta.

A warm worker is no longer the first optimization. Persistent identities reuse
the expensive resolved work without process lifecycle, memory, or invalidation
complexity. Reconsider a daemon only for operations that cannot be represented
as a deterministic build artifact.

## Shipped and superseded plans

These files are retained as implementation history. They are not the active
roadmap and should not override the v3 BRD or doctrine.

| Release | Historical theme | Plan | Disposition |
|---|---|---|---|
| 0.6.0 | **Trust** | [0.6.0-trust.md](0.6.0-trust.md) | Shipped |
| 0.7.0 | **Lint** | [0.7.0-lint.md](0.7.0-lint.md) | Shipped; conformance now continues under v3 P1 |
| 0.8.0 | **Leverage** | [0.8.0-leverage.md](0.8.0-leverage.md) | Shipped |
| 0.10-0.12 | **Intent** | [0.10-intent-surface.md](0.10-intent-surface.md) | Folded into 2.0 |
| 2.0 | **v2 audit closure** | [2.0-v2.md](2.0-v2.md) | Shipped |
| 2.1 | **Resolved** | [2.1-resolved.md](2.1-resolved.md) | Superseded by 3.0 resolved core |

## Standing doctrine (applies to every plan; do not re-derive)

1. Resolved analysis is the default when the host has
   `.dart_tool/package_config.json`. Syntax-only is the automatic zero-setup
   fallback, the explicit `--syntax` opt-out, and the per-file fallback on a
   resolution failure. Explicit `--resolved` without package config refuses
   with a `pub get` instruction.
2. Everything `build` writes under `docs/maps/` is deterministic
   (byte-identical for identical source). `docs/maps/notes/` is the one
   ungated dir. Git/wall-clock allowed in VERB output only.
3. NEVER-GUESS: a wrong edge/violation/skip is a blocker; a missing one is
   fine. Every resolution or selection mechanism ships with an explicit
   refusal gate AND a test proving the refusal. For CI-affecting features
   (affected-tests) the doctrine inverts to FAIL-OPEN: when uncertain, run
   MORE tests, never fewer.
4. v3 does not preserve old graph/wire compatibility; stale graphs rebuild.
   Determinism is still mandatory: identical source and configuration produce
   byte-identical committed artifacts.
5. Query output is line-budgeted; `--json` caps TOTALS with `truncated`.
6. Agents implement stages INCREMENTALLY (land + verify one mechanism before
   the next) — an API death mid-flight must leave a green prefix, not a
   fragment. (Learned 0.5.0: the all-at-once attempt died broken; the
   incremental retry died green.)
7. Gates between stages are run independently by the orchestrator:
   `dart analyze --fatal-infos && dart format --set-exit-if-changed . &&
   dart test && dart test`, plus byte-stability on a reference host where the
   plan demands it.
8. The headline benchmark is the with-vs-without agent delta on task success
   and build-stays-green. Retrieval and performance benchmarks remain
   regression gates.
9. Actuator output is apply-ready and reversible, and refuses whenever target
   resolution or edit-set completeness cannot be proven.

## Rejected / deferred — do not re-propose without a new trigger

(Consolidated from CHANGELOG; the authoritative list lives there.)
- MCP server mode (resident schema tokens dwarf CLI call cost).
- LLM output in generated artifacts; git-churn counts in committed artifacts
  (both break `check()` determinism).
- Per-edit (PostToolUse) regen; 2k-token session injection (passport covers).
- PageRank `map` verb, fold/preview levels, `slice`, BM25 `locate`,
  embedding search — all gated on evidence of need that hasn't appeared.
- Framework extractors beyond Riverpod + GoRouter — revisit only when a
  concrete host supplies evidence of need.
- YAML config — `codegraph.json` chosen (stdlib jsonDecode, zero new deps;
  yaml is only a transitive dep and depending on transitives directly is the
  mistake the analyzer dep already corrected once).

## Not scheduled, kept visible

- Markdown-writer extraction from engine.dart (~360 lines → markdown.dart):
  clean cohesion win, no urgency. Fold into whichever future release next
  touches the writer substantially.
- `passport`/hook UserPromptSubmit per-task packs: still deferred on noise
  risk.
- Windows PowerShell hook: gap, not rejection.
