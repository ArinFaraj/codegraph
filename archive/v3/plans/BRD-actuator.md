# codegraph BRD - from better-grep to actuator

Status: proposed direction, 2026-07-14. This is the north-star document. It
sets WHY the project changes shape and in WHAT ORDER. Each release gets its own
staged plan file (the format plans/ROADMAP.md already uses); this BRD is the
thing those plans are measured against, and the thing we re-read when a plan
tempts us back toward "make lookups a bit better."

## 1. The problem with codegraph as it is

The 2026-07-11 audit put the tool at ~40% of its potential and blamed
syntax-only parsing. That is half right. Syntax-only caps *accuracy*. But even
a perfectly accurate lookup tool has a low ceiling, because of what it is
measured against and what it competes with:

- The CI gate that steers the project (`benchmarks/usefulness`) scores
  recall/precision vs grep. The one harness that measures whether codegraph
  makes an agent's final answer better (`benchmarks/README.md`, "Agent
  quality") is exploratory only, n=1, noisy, and lives outside CI. So the
  project optimizes lookup accuracy, not impact.
- The baseline it beats is "a competent agent with grep + read." That baseline
  is already decent and rises with every model release. Winning it by a few F1
  points on a synthetic fixture is a token-saver, not a tool someone refuses to
  work without.

Diagnosis: codegraph is a better-grep, and better-grep is a ~40% product
forever no matter how accurate it gets. Accuracy is necessary. It is not the
thing that makes the tool matter.

## 2. The reframe

Stop competing on lookup. Own the things grep can NEVER do at any price,
because they need global, resolved, whole-program state that an agent cannot
cheaply reconstruct inside a context window.

codegraph's structural advantage over grep is asymmetry: grep re-derives
everything per session at O(context); codegraph precomputes once at O(1)-to-
query. Spend that asymmetry on work that is impossible file-by-file, not work
that is merely tedious file-by-file.

Concretely, the product changes from an ADVISOR (emits read-only text with a
caveat) to an ACTUATOR (emits something an agent or the tool can execute
against, and a guardrail that refuses unsafe change). The one-sentence pitch
goes from "find code faster" to "change code without breaking it, and keep an
agent-built codebase coherent as it grows."

## 3. North-star metric (change this first, it pulls everything else)

Replace the headline gate. Today: retrieval F1 vs grep. Target: **agent task
success and build-stays-green, with codegraph vs without**, on tasks where a
blind agent measurably breaks things (refactors, conformance, safe change).

Rule: a feature ships only if it moves the with-vs-without agent delta on a
task class that matters, not the retrieval-vs-grep delta. You optimize what you
measure; measure impact.

Secondary (kept, demoted to regression gates, not headlines): the existing
deterministic usefulness + performance suites still guard against silent
correctness/latency regressions. They stop being the definition of success.

## 4. Pillars (what we build), ranked by leverage-per-effort

The pillars are also memory layers of one brain (see plans/knowledge-model.md):
P0 resolved core is the SEMANTIC memory's foundation, P1 conformance and P2
actuator are PROCEDURAL memory (knowledge that acts), P3 data-flow completes the
semantic core as a Code Property Graph. Two faculties cut across all of them -
confidence/provenance (a column on every fact) and personalized salience (what
matters for the current task). The knowledge-model doc is the design of the data
itself; this section is the build order.

### P0 - Resolved core (substrate)
Element identity via the analyzer's resolved element model, opt-in, with
syntax as the zero-setup fallback. This is the audit's own root-cause fix and
the foundation P2/P4 stand on. Viability proven 2026-07-14 (see the spike
result in plans/3.0-resolved-core.md): 99% of call sites resolve to a real
element, cross-file and SDK identity works, cost is a one-time ~4s warmup plus
~12-60ms/file steady state (a ~1500-file host lands under a minute cold,
single-threaded). Memory is the only real constraint (~800MB floor from the
SDK element model) and it only binds the future daemon, not the one-shot build.

### P1 - Conformance layer (cheapest real value, ships first-ish)
Turn `lint` from a seed into the product. Codified architectural invariants
checked on the whole graph and gated in CI:
- layering (dir A must not import dir B),
- pairing (every X must also register/dispose/handle Y),
- must-stay-in-sync (this enum and that switch; this route table and that
  guard).
The ROADMAP's own highest-value sentence: the daily pain is "an AI-developed
repo whose agents drift from the standards nobody enforces." Grep cannot check
cross-cutting invariants; a graph can. A partial version (syntax-level rules:
layering, import boundaries, presence/absence pairs) ships BEFORE P0 lands and
deepens once element identity arrives. This is the stickiness pillar: a
guardrail is something you keep on; a lookup is something you reach for.

### P2 - Actuator / refactor-safety engine (the flagship, needs P0)
Emit apply-ready change sets, not read-only prose. "Change this signature" ->
the exact, element-resolved list of every break through inheritance, overrides,
and tear-offs, each with the edit it needs. This is where blind agents fail
loudly today (refactor, miss three call sites, ship a red build), which is
exactly what makes fixing it feel like a category change rather than a saved
grep. The demo that sells the whole reframe: an agent renames a widely-used
method and the build stays green because codegraph handed it the complete
resolved edit set.

### P3 - Data-flow / lifecycle (deepest, latest, only if P2 proves the thesis)
Beyond "who reads this" to "where does this value flow, mutate, and leak":
input-to-sink reachability, provider state lifecycle, disposal correctness.
Fully impossible for grep. High effort, needs P0 plus real flow analysis. Do
not start here; it is the payoff that makes codegraph irreplaceable if the
earlier pillars land, not the opening move.

## 5. Sequencing

1. Fix the metric (north star, section 3) - cheap, non-breaking, and it is the
   ruler every later bet is judged by. Elevate the agent A/B into a real gate.
2. P0 resolved core - the substrate. First staged plan:
   plans/3.0-resolved-core.md (supersedes plans/2.1-resolved.md, folding it in
   with the measured viability numbers).
3. P1 conformance - start the syntax-level rules early (can overlap P0),
   deepen with element identity once P0 lands.
4. P2 actuator - the flagship, on top of P0.
5. P3 data-flow - only after P2 shows the reasoning-layer thesis pays.

Steps 1 and the syntax slice of 3 do not depend on P0 and can ship value while
P0 is built.

## 6. Doctrine changes this direction forces

- This is v3: backwards compatibility is NOT preserved. Wire format, graph
  format version, CLI defaults, and doctrine change freely; old graphs do not
  need to keep loading (a stale graph rebuilds itself). This is what lets the
  reasoning pillars change the format when it is cleaner to, instead of only
  additively.
- Doctrine item 1 (ROADMAP: "syntax-only; no pub get; Ever") is REPLACED:
  resolved analysis is the DEFAULT; syntax-only is the automatic zero-setup
  fallback (no package_config), the `--syntax` opt-out, and the per-file
  fallback when one file will not resolve. A resolved answer must never be less
  honest than a syntax answer: on resolution failure for a file, fall back to
  syntax for that file and say so. Explicit `--resolved` with no package_config
  refuses with a `pub get` instruction rather than degrading silently.
- NEVER-GUESS is unchanged and now easier to honor: element identity replaces
  name-match heuristics, so wrong edges from same-named symbols disappear by
  construction rather than by allow-list.
- New doctrine: the headline benchmark measures impact (with-vs-without agent
  delta), not retrieval. Retrieval suites are demoted to regression gates.
- New doctrine: any actuator output (P2) is apply-ready and reversible, and
  ships with a refusal gate - when resolution is incomplete for a target, it
  refuses to emit an edit for that target rather than emitting a guess. A wrong
  auto-edit is a far worse failure than a missing one.

## 7. Non-goals (do not let these creep in)

- MCP resident server mode (rejected: resident schema tokens dwarf CLI cost;
  the daemon in P0/later is a socket client of the SAME CLI, not MCP).
- LLM output inside generated/committed artifacts (breaks check() determinism).
- Framework extractors beyond Riverpod + GoRouter unless a concrete host needs
  one (existing standing decision).
- Auto-applying edits without the agent/user in the loop by default; P2 emits
  the change set and can apply on explicit request, never silently.

## 8. Risks

- analyzer version coupling: resolution binds to the host's SDK/analyzer pin.
  Mitigated by the syntax fallback and by testing against the reference host's
  Flutter pin first.
- Memory at daemon scale (~800MB SDK floor + per-file element retention ->
  multiple GB on a large host). Binds the daemon only; measure before making
  resolved the daemon default. The one-shot build exits and reclaims it.
- Determinism: resolved extraction must stay byte-identical for the check()
  gate (sort element iteration, as the syntax path already learned).
- Scope: this is a multi-release redirection. Each pillar lands green and
  standalone; no pillar is allowed to leave a broken prefix (ROADMAP item 6).

## 9. What "done and useful" looks like

An agent working in a host repo:
- cannot merge a change that violates a layering/pairing invariant (P1 catches
  it in review, in CI, before a human sees it),
- can refactor a core signature and the build stays green on the first try
  because codegraph handed it every resolved break and its fix (P2),
- and the with-vs-without A/B shows a large, repeatable delta on exactly those
  task classes (north-star metric), not a few F1 points on lookups.

That is the tool people will not work without. Everything in this BRD is in
service of that sentence.
