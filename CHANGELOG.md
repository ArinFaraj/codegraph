# Changelog

Design history — including rejected ideas. Read this before proposing engine
changes so you don't re-propose a deliberate dead end.

## 3.1.0 - 2026-07-17 - v3 trust follow-through

- **Typed GoRouter topology is now a first-class resolved contract.** Graph
  format 9 adds a deterministic route index built from analyzer-evaluated
  `TypedGoRoute`, `TypedRelativeGoRoute`, `TypedShellRoute`,
  `TypedStatefulShellRoute`, and branch constants. It preserves occurrence
  identity for reusable relative routes, exact nested path patterns, ordered
  stateful branches, shell/branch ancestry, navigator and parent-navigator
  ownership, direct page contracts, and statically exact redirect targets.
  Typed navigation edges now carry stable analyzer route identity plus the
  exact operation, including relative navigation. `route <RouteData>` returns
  the complete placement/page/redirect/caller card with one shared JSON budget
  and refuses unavailable, partial, ambiguous, fake, or dynamic facts instead
  of guessing. Route topology now participates in ordinary impact and
  affected-test traversal. A byte-deterministic stateful-shell oracle freezes
  the topology, and a new executable mutation gate starts green, applies a
  real page mutation, runs the entire test universe, and proves zero omitted
  failing tests. The older affected-test benchmark remains a frozen set oracle,
  not evidence that mutations were executed.

- **`affected-tests` ships as an explainable, fail-open planning surface.** It
  consumes explicit paths or a merge-base Git change set, computes the full
  reverse production dependency closure, scans runnable `*_test.dart`
  entrypoints through test helpers/parts and local packages, and emits complete
  package/runner argv arrays with per-test witnesses. Machine plans are never
  budget-truncated. Deleted inputs, stale/unknown graph state, parse failures,
  global/config/generated/platform/asset/route boundaries, Patrol uncertainty,
  and zero-test production selections expand to workspace suites. Targeted
  plans remain explicitly advisory until the mutation oracle proves zero
  omitted failing suites. The frozen thirteen-scenario CI set oracle gates exact
  static and resolved-symbol sets, full expansion, determinism, framework
  edges, runner commands, and zero omissions; it currently reports an 86.7%
  targeted reduction with low-single-digit-millisecond plans.
- **Resolved builds now connect typed GoRouter navigation to built pages.** A
  navigation such as `const AccountRoute().go(context)` is recognized from the
  receiver's analyzer identity when its class extends the real
  `package:go_router` `GoRouteData` or `RelativeGoRouteData`. Direct expression
  returns and exact single-return `build`/`buildPage` bodies resolve through the
  existing conservative page-wrapper rules, producing resolved `navigates` and
  `navigates-to` edges that immediately improve wiring, impact, and
  `affected-tests`. Same-named route classes retain library identity; local fake
  bases, dynamic receivers, conditional bodies, and ambiguous pages refuse.
  This receiver-to-page layer is now superseded by the format-9 typed-route
  topology above.
- **Tracked body edits now receive resolved changed-symbol attribution.** Git
  status remains NUL-delimited, while deterministic per-path zero-context hunks
  are matched against executable bodies in both the merge-base and current
  source. Stable symbols propagate through resolved caller ownership, override
  components, test helpers, and runnable entrypoints, avoiding unrelated tests
  that only import the same file. Every unsupported or ambiguous boundary is a
  visible `precisionFallback`, never a narrower guess; targeted output remains
  advisory. The refactor index format is now 4 and records declaration/body
  spans plus each reference's enclosing executable. Host and local-package test
  roots now share one deterministic enumerator across freshness, resolved index,
  graph test credits, callers, and rename fallbacks.
- **Rename apply is now prevalidated and rollback-backed across files.** Every
  target is read and every expected span, duplicate, overlap, path alias, and
  collision is checked before the first staged write. Outputs and recovery
  backups are flushed beside their targets, file modes/BOM/line endings are
  preserved, originals are revalidated before install, and an install failure
  restores attempted files in reverse order. Incomplete rollback reports and
  retains the exact recovery backup. Same-scope declaration collisions now
  refuse before apply. Portable filesystems cannot provide one atomic rename
  over multiple paths, so the contract is explicit transaction-like rollback,
  not an impossible atomicity claim.
- **Resolved builds understand source-declared Riverpod codegen contracts.**
  Functions and Notifier classes annotated by the real
  `package:riverpod_annotation` element produce their generated provider names,
  provider kinds, auto-dispose/keep-alive lifecycle, and reader edges without
  parsing generated files. A same-spelled local annotation is deliberately
  ignored. `ref.invalidate` and `ref.refresh` are now first-class provider
  interactions in queries, impact, unused detection, maps, and blueprints.
- **Resolved refactors are now graph-speed after build.** A resolved build
  writes a deterministic, gitignored `refactor_index.json` containing stable
  executable identities, declarations, references, and override links across
  production and test code. `rename` uses it when complete and source-current,
  while retaining the cold analyzer path as a compatibility fallback. Syntax
  builds delete the index rather than risk stale semantic edits. The indexed
  path preserves all actuator gates: unrelated same-name methods are excluded,
  whole in-project override sets move together, external override contracts
  ambiguous targets and unresolved/dynamic target spellings still refuse, and
  test call sites are included. The public fixture benchmark measures 11 ms
  indexed vs 446 ms query-time analysis on the development machine (40.5x);
  CI requires at least 5x.
- **Resolved callers and references now use the same semantic index.** The
  artifact records call-vs-reference kind, stable targets (including honest
  unresolved targets), line locations, and override ancestry. Output remains
  parity-tested against a fresh analyzer walk, with an additive `indexed: true`
  proof in JSON. The public benchmark measures 4 ms indexed vs 328 ms fresh
  analysis (82x), and CI requires at least 5x.
- **Stale-query rebuilds and `check` now preserve resolved-by-default
  analysis.** The v3 `build` command selected resolved analysis when a host had
  `.dart_tool/package_config.json`, but the older synchronous freshness and CI
  paths still called the syntax builder directly. The first query after an edit
  (and every `codegraph check`) could therefore silently replace a resolved
  graph with heuristic-only edges. Build-mode selection now has one shared
  policy entry point; the async CLI freshness preflight and `check` both use it,
  while no-package hosts retain the zero-setup syntax fallback. A regression
  test proves a stale configured host still emits element-resolved subtype
  edges after automatic rebuilding.
- **Value-taking flags no longer leak into query operands.** Shared positional
  parsing now removes both `--budget`/`--depth`/`--base` and their values. This
  fixes a production-host failure where `find vault --budget 20` searched for
  both `vault` and `20` and confidently returned no matches.
- **Reader caveats now reflect v3 resolution.** A resolved-build regression
  fixture proves `box.ref.read(provider)` is found from the wrapper field's
  static `Ref` type; query output now limits the warning to syntax fallback
  instead of claiming wrapper-held refs are always invisible.
- **Pathological branch comparisons are explicit.** `review`/`diff` now warns
  when at least 500 Dart files differ from the selected base and suggests an
  explicit tracking ref, while preserving the requested comparison semantics.
- **Resolved operations report progress.** Resolved build, callers/refs, and
  rename now emit rate-limited file progress on stderr, keeping stdout and JSON
  contracts stable while making long analyzer work visibly alive.

## 3.0.0 - 2026-07-14 - "v3" (resolved analysis + the actuator turn)

The direction change: from a better-grep to a resolved knowledge-and-action
system. The 2.0 audit's verdict was that every documented ceiling traced to one
decision - syntax-only parsing. 3.0 reopens it. This is v3: NO backwards
compatibility - wire format, graph shape, CLI defaults, and doctrine all change
freely; a stale graph rebuilds itself. Design docs: plans/BRD-actuator.md
(vision), plans/knowledge-model.md (the layered-memory model), plans/
3.0-resolved-core.md and plans/3.1-actuator-rename.md (execution). Validated at
every step on a production-scale Flutter codebase.

### Resolved analysis is the default

- **`build` resolves by default** via the analyzer's element model
  (`AnalysisContextCollection`). Syntax-only is the automatic zero-setup
  fallback (no `.dart_tool/package_config.json`), the explicit `--syntax`
  opt-out, and the per-file fallback when one file will not resolve. Explicit
  `--resolved` with no package_config refuses with a `pub get` instruction.
  Cost on the reference host: ~33s / ~2.3GB cold vs ~2.5s / 230MB syntax - the
  "once in a while" build budget. Doctrine item 1 ("syntax-only; Ever") is
  replaced.
- **GoRoute constructor form**: syntax parsing misparses `GoRoute(...)` as a
  method call; under resolution it is an InstanceCreationExpression. The
  extractor now handles both, so resolved builds stay at least as complete as
  syntax (found via the reference host - resolved had been dropping 39 nav
  edges).

### Element identity where name-match was wrong (the ceilings fall)

- **readers by receiver type**: a `.watch/.read/.listen` receiver is a reader
  when its STATIC TYPE is (a subtype of) Ref/WidgetRef/ProviderContainer,
  whatever it is named - catches renamed parameters, aliases, and container
  getters the name allow-list misses (+23 real reader edges on the reference
  host, 0 lost).
- **subtype edges** carry element-confirmed identity; on the large validation
  corpus all observed implements/extends edges resolved successfully.
- **`GraphEdge.confidence`** = `resolved | heuristic | guessed` - the
  NEVER-GUESS doctrine as a queryable column (emitted only when not
  `heuristic`). `readers` marks `[unconfirmed]` (name-matched, not
  element-confirmed) edges in a resolved build. Build prints an honesty metric
  (element-resolved reader / subtype fraction).

### callers/refs and the actuator

- **`callers|refs <Symbol> --resolved`**: element-precise, attributes each call
  site to its real target (`HomePage.build` vs `SettingsPage.build`) instead of
  lumping every same-named method, and reports the target's inheritance override
  chain (external/framework base = unsafe to touch). The refactor-safety brain,
  read-only. Query-time whole-context resolution (slow; opt-in).
- **`rename <Symbol|Class.method> <newName>`** - the first WRITE actuator.
  Element-precise: renames the declaration and every element-resolved reference,
  including a whole in-project override set (base + all overrides + siblings +
  call sites) together. Refuses anything it cannot do completely and safely -
  ambiguous target, external/framework-base override, incomplete resolution,
  missing package_config - every failure a refusal with a reason, never a
  partial (build-breaking) edit. Dry-run by default; `--apply` writes; refusal
  exit code 3. Current releases cache rename identities at resolved-build time;
  this section describes the original query-time implementation.

### Deferred (not in 3.0)

- The warm daemon (fast resolved queries) - the resolved query cost is the
  "once in a while" case, so this waits on evidence the latency is real
  friction. Signature-change actuator and whole-hierarchy public-API scope
  checks are the next actuator frontier.

## 2.0.0 - 2026-07-11 - "v2" (the everything-the-audit-found release)

A four-lens adversarial audit (architecture, positioning, correctness
ceilings, measured performance) found the engine precise but the surface,
structure, and disclosures at ~40% of potential. 2.0 fixes every finding
fixable inside the syntax-only execution model (plans/2.0-v2.md; the
resolved-analysis daemon is 2.1). Wire format 5 -> 6.

### Intent surface (plans/0.10-intent-surface.md)

- **Five intent verbs**, composed from the existing internals, are now the
  front door: `uses <thing>` (every inbound relation, sections auto-picked by
  what the argument resolves to - provider readers, impls tree, call sites,
  or a file's inbound wiring), `change <thing>` (the pre-change pack:
  depth-2 dependents + the Notifier subtype tree + state-type follow-ups +
  untested-in-blast-radius - kills the canonical "renamed the provider,
  missed the subclasses" failure), `review` (= diff: blast radius +
  changed-but-untested + lint new-violations), `health` (attention + unused +
  untested in one card), `plan` (= blueprint). Old verbs remain as the
  low-level surface; help text restructured to 30 lines, intent verbs first.
- **Exit-code contract**: 0 answered (typed empties included), 2 ambiguous
  file argument (candidates listed), 64 usage, 66 no graph.

### Structure (the architecture audit's findings, all fixed)

- **ONE shared file-arg resolver** (lib/src/resolve.dart, typed
  Resolved/Ambiguous/NotFound) replaces six divergent per-verb copies that
  could resolve the same input four different ways (wiring had no tiebreak,
  brief missed the `:$arg` suffix case). Ambiguity now refuses consistently
  and exits 2 everywhere.
- **registry.dart extraction**: FileInfo + decl record types moved out of
  engine.dart; the engine<->nav_resolution import cycle is genuinely broken.
- **Engine module globals gone**: `_self`/`_packages` are parameters threaded
  through parsing; nav counters returned from `_writeGraph` instead of reset
  globals.
- **Typed subtype edges**: implements/extends edges carry `child`/`parent`
  fields; the `' -> '` detail-string re-parsing is dead (format 6; `detail`
  kept for display).
- **LintConfig.load throws** (LintConfigException) instead of exit()ing
  library-deep; lint's CLI behavior unchanged; diff's lint section now
  degrades instead of dying on malformed codegraph.json.
- Hygiene: `providerConsumerRels`/`untestedRoles` constants replace 9
  copy-pasted literal sets; skeleton/brief/attention shadow copies of
  cli_util functions deleted; one `runGit` guard replaces 6 hand-rolled
  ProcessException guards.

### Correctness

- **callchain ambiguity bug fixed**: an ambiguous callee landing exactly at
  the depth cap silently resolved to `decls.first` (file/line/hazards of the
  wrong body) - the refusal is now unconditional. Regression fixture added.
- **Mixin `on` constraints and extension-type `implements`** are captured as
  subtype edges (stated facts previously dropped silently by _collect).
- **Parse diagnostics surfaced**: build prints one stderr line when N files
  had parse errors (a half-edited file no longer folds silently into truth).
- **Under-disclosed gaps now disclosed at use time** (caveat registry + the
  LIMITATIONS seed): ProviderScope overrides are not modeled (who SUBSCRIBES
  vs which implementation RUNS), callers/refs same-name count inflation
  (plus an additive `ambiguousDeclarations` JSON key), family-provider
  collapse to one node, testRefs cross-declaration credit bleed.

### Performance / ops

- **Freshness stat fast path**: queries check a stat digest (path+size+mtime)
  first and only fall back to the full content hash on mismatch - the
  ~150ms/query content walk drops to a stat walk when nothing changed. A
  query never writes; mtime churn without content change costs the fallback
  until the next build.
- `--no-rebuild` now skips the digest walk entirely (freshness reported as
  "unchecked", never claimed).
- **Version lock test**: binaryVersion must equal pubspec version (they had
  already drifted once). Host scaffolding templates now pin activation to
  `--git-ref v<version>` instead of silently tracking main.

## 0.10.0 - folded into 2.0.0 - "Trust the envelope" (shipped as part of 2.0.0)

- **A stale graph can no longer answer silently.** `build` stores a
  deterministic content digest of everything it read (`stats.sourceDigest`,
  FNV-1a 64 over host pubspec + each scanned .dart file's path and content -
  no wall clock, so identical source still produces byte-identical output and
  the `check()` gate is unaffected; inserted before `testFiles` so both
  pinned stats positions hold). Every query verb re-derives the digest and,
  on mismatch or missing graph, AUTO-REBUILDS in place (~2s on a 1.5k-file
  host, one stderr line, stdout untouched so `--json` stays parseable), then
  answers from the fresh graph. Global `--no-rebuild` opts out (stale answers
  carry a stderr warning). This deletes the documented trap where `find`
  returned "(no matches)" for a symbol that plainly existed because the graph
  predated the file. Steady-state cost when fresh: the digest walk, well
  under 100ms on the reference host.
- **Typed empty results.** A bare "(no matches)" never appears again - every
  not-found states the graph's freshness and file count ("no matches (graph
  fresh, 1519 files indexed)"), or flags GRAPH STALE when --no-rebuild kept an
  old graph. `impls` now distinguishes "no subtypes - X is declared at
  file:line" (a real answer) from "no such type" (absence); `callers` with a
  known declaration but zero sites says so instead of a generic none.
- **Caveats travel with answers.** Every query verb's text output ends with a
  one-line scope caveat from a single registry in cli_util.dart (e.g.
  readers: "file-level and lib-only; reads through wrapper objects
  (x.ref.read) are not detected"; unused: "CANDIDATES, not verdicts...").
  LIMITATIONS.md remains the long-form registry; the answer now carries the
  line that prevents over-trust at the moment of use.
- **Shared --json envelope (additive).** Query verbs now emit `fresh` (bool)
  and `caveats` (list) alongside the existing keys via one `envelope()`
  helper; no existing key moved or changed, so downstream parsers are
  unaffected. Exit-code contract note: 0 = answered (typed empties included);
  a distinct cannot-answer code lands with the shared resolver (the only
  stage-1 item deferred - no verb hard-refuses today, so there is no trigger
  path yet).

## 0.9.8 - 2026-07-10 - benchmark overhaul (the "measure honestly" release)

An external review of the whole benchmark story (four parallel audit agents +
hand ground-truthing on the reference host) found the harnesses were partly
measuring themselves. Everything below is fixes to measurement, plus one CLI
surface change.

- **`impls` now surfaces `ambiguous` on subtype edges** (JSON field + an
  `[AMBIGUOUS: ...]` text marker). The refuse-not-guess doctrine existed only
  on the in-memory edge before; a real agent running the CLI got a confident,
  unqualified answer. The usefulness scenario now checks the SHIPPED surface.
- **Usefulness benchmark is now an actual CI gate.** It was documented as
  "the CI gate" but was not in ci.yml and had no pass/fail logic at all
  (always exit 0). New: committed per-scenario recall/precision floors
  (`usefulness/baseline.json`), `--check` fails on any drop, `--write-baseline`
  refreshes after deliberate changes, CI runs `--check` on every push.
- **Grep-arm harness bugs fixed** (they inflated codegraph's win):
  - the impact recipe located seed files by grepping their own CONTENT for
    their filename (a file rarely mentions its own name) and matched importers
    on the on-disk `lib/` path, which can never appear in a `package:` import.
    Its 0.00 F1 was a harness bug, not a grep weakness - it now scores 1.00
    on the same scenario (codegraph still wins on tool calls, 1 vs 4).
  - the output-size metric compared codegraph's newline count (always 1:
    single-line JSON) against grep's item count. Now `outputChars` on both
    arms.
  - grep tool-call constants documented as charitable lower bounds, not
    measured counts.
- **Agent-quality (LLM) harness moved to the reference host repo** and
  rebuilt. The committed copy violated the honesty doctrine in 8 of 13
  scenarios: `gt` fields literally told the judge to run codegraph to
  establish ground truth (circular - the exact failure mode the usefulness
  README warns about), the two arms ran different scenario sets under
  different judge rubrics (scores not comparable), the judge did the weighted
  arithmetic itself, and the 0.9.7 name-scrubbing had left symbol names that
  do not exist on the host (scenarios unrunnable as committed). Host-specific
  scenarios cannot be both runnable and name-free, so they now live in the
  private host repo (`tools/codegraph_bench/`); both arms share one scenario
  set + one judge rubric, judges are forbidden codegraph for truth in BOTH
  arms, aggregates are computed in code, and results pin the host commit.
  Old scores (the "overall 91" baseline) are not comparable to new runs.
  Removed stale README claims: behavioral 2x weighting (never implemented),
  "+/-2 noise" (never measured).
- **New real-repo regression suite** in the reference host
  (`tools/codegraph_bench/run.dart`): 12 deterministic invariant checks
  against rg-verified frozen truth at a pinned host commit, each guarding a
  specific historical bug (cascade readers, test-fake impls, duplicate-symbol
  scale, barrel export closure, field-held refs, comment false positives,
  phrase find, member sym, backup-dir shadowing, non-provider redirect).
  Includes one `xfail`: reads through wrapper-object receivers
  (`x.ref.read(...)` where the wrapper is not a known ref name) are invisible
  to the engine's literal receiver allow-list - found while ground-truthing,
  encoded as a known gap that flips visible when fixed.

## 0.9.7 — 2026-07-08 — docs-hygiene doctrine in all agent templates

- **Skill, CLAUDE.md block, Cursor rule, and LIMITATIONS seed** now carry an
  explicit rule: committed agent guidance (LIMITATIONS entries, area notes)
  must use generic descriptions only — never name a specific product, vendor
  SDK, or private project.
- **Skill verb list** synced with the CLAUDE block (`callers`, `callchain`,
  `impact`, `diff`, `untested`).
- **Benchmark scenarios + internal comments** generalized (no host-specific file
  or provider names in agent-facing harness text).

## 0.9.6 — 2026-07-08 — skill/LIMITATIONS on upgrade + public-repo hygiene

- **`code-map` skill + `upgrade` output** now tell agents to review
  `docs/maps/LIMITATIONS.md` after a CLI upgrade — merge new known gaps from
  the release notes (upgrade refreshes skill/hook but never overwrites
  LIMITATIONS).
- **CI format gate** fixed — usefulness benchmark sources were unformatted.
- **Project-specific names scrubbed** from changelog, docs, comments, plans, and
  benchmark scenarios (generic examples only in the public repo).

## 0.9.5 — 2026-07-08 — readers casing + documented remaining gaps

Patch release after dogfooding 0.9.4 on a large production monorepo confirmed
the big fixes hold; three ergonomics gaps remain (two documented, one fixed here).

- **`readers <NonProvider>` redirect is now case-insensitive on symbol names.**
  `readers SessionToken` already redirected correctly; `readers sessionToken`
  (camelCase field spelling) still said "misspelled" because the symbol lookup
  was exact-match. Now uses the same case-insensitive resolution as `brief`/
  `find`, and prints the canonical symbol name in the redirect.
- **LIMITATIONS seed updated** with the three remaining query gaps from
  real-project review: field/member *access* invisible to `callers` (method
  calls only), `impact` doesn't resolve method names (use `callers` + `impls`
  for a signature-change blast radius), and OpenAPI/generated-model field
  removals still need a `git diff` on the API package.
- **README + landing page** brought current with 0.9.x verbs (`callers`,
  `callchain`, `refs`), `sym`/`brief` member resolution, `impls` test fakes,
  and the interface-signature-change workflow.

Tests: +1 (readers redirect case-insensitive); 181 total.

## 0.9.4 — 2026-07-07 — class-name resolution joins the "never a wrong edge" doctrine + query-honesty fixes

An external review found that the type/nav half of the graph never got the
ambiguity discipline the provider resolver has had since 0.3.0, plus a cluster
of "confident but possibly wrong / silently truncated" spots. All are fixes to
existing behavior (no new verbs, no scaffolding change → patch-level; hosts are
NOT re-nagged to re-scaffold, per the 0.9.2 patch doctrine).

- **Duplicate class names no longer produce silent WRONG edges.** The class
  registry was `putIfAbsent` first-declaration-wins with no ambiguity check, so
  a supertype/page NAME shared by two features (the common `HomePage` /
  `DetailsPage` / `State` case) resolved to whichever file parsed first — a
  confident wrong `implements/extends` edge and, worse, a wrong `navigates-to`
  page edge even though the path→route side was perfectly gated. New
  `ClassResolver` (resolution.dart) mirrors `ProviderResolver` exactly: a unique
  name resolves directly; an ambiguous name resolves ONLY when import
  reachability from the reader narrows it to exactly one declaration, else it
  REFUSES — the type edge becomes `type:<name>` with `ambiguous: true` +
  `candidates` (parallel to an unresolved ambiguous provider edge), and the nav
  edge stays unresolved rather than guessing. Shared by the type edges and both
  nav page-resolution sites (route table + `goNamed` name table), so the name
  table also gains the reader-reachability gate it previously lacked. No
  wire-format field added (`ambiguous`/`candidates` already existed); output
  changes only for projects that actually have duplicate class names.
- **`callers`/`refs` now disclose method-name ambiguity.** The "`$sym` has N
  declarations — sites match across all of them" note was built only from
  top-level symbol names, but methods live in `SymbolRec.members` as strings, so
  for any METHOD query the note never fired — two unrelated `delete()` methods
  were unioned into one authoritative-looking call-site list with no warning.
  Member declarations are now counted, so the note fires.
- **`callchain` hazard flags are scoped to the method's own body.** `_BodyScan`
  descended into nested closures and local functions, so hazards inside a
  callback (`onTap: () {...}`) or a nested `void inner() {}` mis-flagged the
  enclosing method. A shared `NestedFunctionBoundary` mixin (also used by
  `_ReturnFinder`) stops at function-expression and function-declaration
  boundaries.
- **`find` no longer invents a phantom `Class.more` member** from the "… N more"
  render trailer (now skipped). Members past the 12-render cap are indexed via
  optional `mi` on symbol records (wire format **5**) so `find` still locates
  them.
- **`--json` truncation is no longer silent on `find` and `sym`.** `find` adds a
  `truncated` count (matching the other verbs); `sym` adds a `truncated` count
  for the 5-item substring-fallback cap and an `importedByTotal` for the
  per-record importer cap, plus a one-line text note.
- **Structural cleanup (no behavior change intended).** `Reachability`,
  `ProviderResolver`, `ClassResolver`, and decl types extracted to
  `resolution.dart`; `ClassResolver.typeEdgeFieldsFor` mirrors provider
  `edgeFieldsFor`; member-name parsing unified in `signatures.dart`
  (`parseRenderedMember`); `Graph.declarationsOf` shared by `callers`/`refs`;
  test fixture extracted to `test/fixture.dart`.
- **Performance benchmark.** `benchmarks/perf.dart` + `perf_baseline.json`
  measure build + query median times on the test fixture; CI compares against
  the baseline (15% / 25ms regression gate). Post-refactor: build ~49ms median
  (was ~69ms pre-extract on the same fixture).
- **Multi-package builds are deterministic.** `_localPackages` walked
  `packages/*` in filesystem order (`listSync`), so node/edge order and the
  winner of any cross-package name collision varied across machines — a
  `check()` CI false-failure on monorepos. It now sorts by path.
- **The usefulness benchmark can finally fail.** Its ground truth was DERIVED
  from the built graph and codegraph was then scored against it — circular: an
  engine regression that dropped a real reader dropped it from truth too, so
  recall stayed 1.0 and the regression was invisible. Truth is now frozen,
  hand-verified literals in `benchmarks/usefulness/scenarios.dart`, independent
  of both codegraph and grep, so a miss turns recall red. Deleted the circular
  `truth.dart` + `generate_ground_truth.dart` + `ground_truth/` snapshots. Added
  a `provider-readers-precision` scenario — the suite's first false-POSITIVE
  guard (readers of `counterProvider` must exclude a non-ref `_Bag.listen` and a
  bare-token mention; grep gets fooled, codegraph must not). Same fix on the
  agent-quality benchmark: the Opus judge now establishes ground truth WITHOUT
  codegraph (ripgrep + source + `dart analyze`), so a false edge the agent
  trusted is caught, not blessed.
- **The installed `code-map` skill + CLAUDE.md block are calibrated for trust.**
  They said "query the graph, don't grep" and called it "accurate" — the exact
  framing that turns a silent-wrong-edge into a confidently-wrong agent. Reworded
  to "query first, verify before you trust": the graph is a fast index, read the
  file it points at before relying on a load-bearing claim.
- **Stray package copies no longer shadow the real package (silent WRONG edges).**
  Package discovery scanned every `packages/*/pubspec.yaml` and did
  `map[name] = dir`, so a stray copy declaring the same package name (a
  `foo_api_backup_<ts>/` whose pubspec still says `name: foo_api`) OVERWROTE the
  real package: every `package:foo_api/...` import, and `find`/`callchain`,
  resolved into the backup. Discovery now follows the host pubspec's `path:`
  dependencies transitively (what `pub` resolves), so unreferenced copies are
  excluded; a `packages/`-scan fallback (first-wins by sorted path) still covers
  projects that declare no path deps. Found on a real 1500-file host where
  `find FooApi` pointed at a backup dir.
- **`sym` / `brief` resolve method (member) names.** Both only matched top-level
  symbols, so `sym <method>` returned "no match" while `find`/`callers` worked.
  They now fall back to a member search (reusing the member index) and show the
  declaring class + file:line (+ signature when the member is within the render
  cap), across every declaration of the name.
- **`impls` surfaces test/integration fakes.** The graph is lib-only, so a
  `_FakeRepo implements Repo` used only under `test/` was invisible — the blind
  spot that bites on an interface signature change. `impls` now scans the same
  test roots `callers` does (new `test_impls.dart`) and lists test subtypes in a
  separate `test fakes` section with file:line, never mixed into resolved lib
  edges. On the reference host `impls AuthRepository` went from 2 rows to
  2 + ~10 test doubles.

Deliberately deferred: unifying ambiguous-provider in-degree (the resolved
`@file` node and the unresolved bare-`provider:name` bucket count reader edges
under separate keys, so ranking under-counts an ambiguous provider's readers).
The fix touches the cached in-degree every ranking reads and wants its own
eval — logged here so it isn't lost.

Not addressed (out of scope by request): `@riverpod` code-generated providers
remain undetected — the generated `xProvider` lives in an excluded `.g.dart`, so
only manual provider declarations are seen. A modern codegen-based app should
treat provider coverage as partial until this is handled.

Tests: +8 (duplicate-class refuse-or-narrow, find past member cap, path-dep
package resolution beats backup copies, sym/brief member fallback x2, impls test
fakes); 180 total.
Usefulness benchmark: 12 scenarios, frozen truth, codegraph 9 wins / 0 losses /
3 ties vs grep, avg F1 0.96 vs 0.71 at a fraction of the tool calls.
Verified: `dart analyze && dart test && dart run benchmarks/perf.dart --compare benchmarks/perf_baseline.json`.

## 0.9.3 — 2026-07-04 — cascade-listen readers + two query-ergonomics fixes

Three real gaps hit while dogfooding on a production monorepo (all fixes to existing
behavior — no new verbs, no scaffolding change, so patch-level; the skew nudge
won't re-nag hosts to re-scaffold).

- **Cascade `..listen`/`..read`/`..watch` are now counted as reader edges.**
  Reader detection extracted the receiver via `node.target`, which is null for
  a cascade section (`ref..listen(p)..read(q)` — the receiver lives on the
  `CascadeExpression`), so the whole class of keep-alive cascades
  (`someRef..listen(deviceTokenProvider, (_, _) {})` in a lifecycle handler)
  was invisible — those providers showed as **zero-consumer** in
  `readers`/`attention`/`unused`/`untested`, a false-positive I had to manually
  debunk mid-review. Fix: extract via `node.realTarget` (resolves the cascade
  receiver; identical to `target` for non-cascades, null for bare
  extension-on-Ref calls which still route through the `_refExtensionDepth`
  branch). The `_refReceivers` gate is unchanged, so a cascade on a NON-ref
  receiver (`_Bag()..listen(p)`) is still refused — verified by a negative test.
- **`find "delete device"` (a single quoted arg with a space) no longer
  false-negatives.** It substring-matched the whole spaced string, which never
  appears in an identifier, returning `(no matches)` that reads as "doesn't
  exist". Now a single arg is split on whitespace into terms, so a phrase
  matches tokens the way the multi-arg form (`find delete device`) already did.
- **`readers <NonProvider>` stops implying the name is misspelled.**
  `readers KrdSectionHeader` (a widget) said "external or misspelled"; now, when
  the name resolves to a real symbol, it says "X is a class, not a provider —
  use `find X` or `wiring <file>`" (uses the symbol's own kind).

Tests: +3 (cascade positive + non-ref refusal, phrase split, readers redirect);
172 total.

## 0.9.2 — 2026-07-04 — patch-tolerant upgrade nudge (kill the per-patch churn)

The scaffolding skew nudge fired on EVERY release, re-nagging every host to run
`codegraph upgrade` even for pure-fix patches that change nothing in the
scaffolding — needless churn. `skewOf` now compares MAJOR+MINOR only: a patch
release is treated as current (no nag); a minor/major bump (which is where new
verbs / scaffolding changes ship, per semver) still nags. Verified callchain
holds up: hazard flags don't false-positive on simple methods, deterministic,
crash-safe on non-method symbols.

## 0.9.1 — 2026-07-04 — `callchain`: static call tree + control-flow hazard flags

The capability hunt's flagship recommendation — the "changes how an agent works"
feature. Every debug/trace task had to hand-read 6+ full method bodies to answer
"what actually runs when this is called, and where might it early-out / skip /
swallow?". codegraph got the agent to the right file, then went dark exactly
where the answer lived.

- **`codegraph callchain <Symbol> [--depth N]`** — one parse pass builds a
  call-graph (name → callees + hazards), then walks it from an entry method,
  cycle-guarded and depth-capped. Each method is annotated with the control-flow
  hazards visible WITHOUT type resolution: `[guard]` (early-return), `[try]`,
  `[swallow]` (empty catch — swallowed exception), `[async]` (`unawaited(...)`).
  So 6 blind reads become 1-2 targeted reads of only the flagged bodies. `--json`
  with a nested tree + legend. On the reference host, `callchain handleResume`
  renders the whole app-resume flow and flags `handleResume [guard async]` — the
  early-return + fire-and-forget the debug evals hand-read to find.
- Never-guess: callees resolve by NAME (syntax-only). A callee with one repo
  declaration is followed; an AMBIGUOUS name is shown but not guessed into; an
  external/SDK name is a leaf. The output states plainly it is name-based
  (approximate) — a branch may follow a same-named method on another type, so
  the agent confirms via the flagged bodies. It is a fast pointer to the right
  bodies, not a proven type-resolved call graph.

## 0.9.0 — 2026-07-04 — `callers`/`refs`: symbol-precise call sites (the #1 evidence-backed gap)

After the project felt bloated with diminishing returns, ran a capability-gap
hunt: 6 hard AI tasks (debug a call chain, refactor a method signature, trace a
dataflow, extend a flow) with agents logging every grep/read they fell back to,
then a synthesizer ranking the missing capabilities. The #1 by a wide margin
(4 of 6 tasks, high impact, and flagged in earlier eval rounds too): NO
symbol-precise call/reference lister. `find` gives a symbol's DECLARATION,
`readers` gives PROVIDER edges, `impact` gives WHOLE-FILE blast radius — none
answers "who calls THIS method?", so every refactor/debug/trace fell back to grep.

- **`codegraph callers <Symbol>`** — every call site (`file:line` + the source
  line) of a method/function, AST-accurate (no comment/string false hits; catches
  `super.x()` and `a.x()`), ranked by containing-file in-degree, `--json`. Scans
  the graph's files PLUS `test/`+`integration_test/`+`patrol_test/` (a signature
  change breaks tests too — those dirs are outside the graph). On the reference
  host `callers deleteJwt` returns the 9 exact call sites across lib + tests that
  every eval round had been grepping for.
- **`codegraph refs <Symbol>`** — superset: calls + tear-offs + type/case
  references, for "everywhere this name is used in code" (the declaration site
  itself is excluded).
- Syntax-only, so matching is by NAME; an ambiguous name reports how many
  declarations exist. On-demand scan (like `skeleton`) with a textual pre-filter
  — no graph bloat.

This is a genuinely NEW capability (method-level references — the tool stopped at
import/provider granularity before), not another completeness patch. The gap hunt
also surfaced the next candidate (`callchain` — a static call-tree walker with
control-flow hazard flags) and flagged verbs unused across all 6 hard tasks
(blueprint/passport/attention/lint/unused/untested) as consolidation candidates.

## 0.8.6 — 2026-07-04 — benchmark re-run: ProviderContainer.read reads

Re-ran the benchmark on 0.8.5 and read the judge's EXACT missed-file list (the
reliable signal — the aggregate wobbles within agent/judge noise). The
`extension on Ref` fix was confirmed working (ref_extension now credited), and
the next concrete reader form surfaced:

- **`container.read`/`.listen(provider)` (ProviderContainer) is now detected.**
  Bootstrap/dialog/dev code reads providers off a `ProviderContainer`
  (`container.read(jwtProvider.future)` in key_prompt_extension, jwt_dialog_manager)
  — receiver `container`, previously invisible. Added `container`/`_container`
  (+ `this.` forms) to the recognized receivers; still arg-gated on a real
  provider, so the generic name adds no guessed edges (verified: 511/513 reads
  resolve to a declared provider node, zero garbage).

**Documented residual (known limitation, no wrong edges):** a cascade
`ref..listen(provider.select(...))` and container/ref `..listen` cascade forms
(e.g. refresher.dart) are still missed — the cascade section has no explicit
receiver AST node. Rare; a bug-hunter cross-checks a specific provider with grep.
Reader detection now covers: `ref`/`_ref`/`widgetRef`/`container` receivers (+
`this.`/`_` variants) AND bare `read/watch/listen` inside a `*Ref` extension.

## 0.8.5 — 2026-07-04 — benchmark-driven: detect bare reads inside `extension on Ref`

Built a repeatable quality BENCHMARK (8 scenarios scored 0-100 by Opus judges on
correctness/completeness/calibration/efficiency vs self-established ground truth;
`benchmarks/`). The baseline (overall 91) did two things: it DEBUNKED a
hypothesized fix — the "codegraph induces over-confidence on behavioral
questions" worry was not systematic (both behavioral scenarios scored 94-95;
agents read source and calibrated well) — and it pinpointed the real weak spot:
the auth-readers scenario scored completeness 71 because `readers` MISSED a whole
class of readers.

- **Bare `read`/`watch`/`listen(provider)` inside an `extension on Ref` /
  `on WidgetRef` are now detected.** The implicit receiver IS the Ref (e.g.
  `ref_extension.dart`'s `isAuthenticated` getter does `read(jwtProvider)` with
  no `ref.` prefix), so these had no explicit receiver and were invisible —
  under-reporting an app-wide auth-state reader and leaving `jwtProvider`'s
  `listens` empty. Now the visitor tracks enclosing `*Ref` extensions and credits
  bare read/watch/listen there (still gated on the arg resolving to a real
  provider — no guessed edges). On the reference host: `readers jwtProvider` now
  includes `ref_extension.dart` in reads/watches/listens; +12 real edges
  graph-wide, 493/495 reads resolving to a real provider node (zero garbage).

The benchmark is committed so future changes are MEASURED, not asserted.

## 0.8.4 — 2026-07-04 — third A/B eval round (workflow-orchestrated): diff/impact --json, transitive impls

A third eval — a multi-agent workflow running four new task types (root-cause
debugging, multi-package boundary audit, branch-risk review, inheritance-tree
understanding) with paired grep/codegraph agents and an Opus judge per scenario
that established its own ground truth and reproduced every gap. codegraph won
multi-package (one `sym` call gave the full cross-boundary import graph, 37 =
29 lib + 7 wrappers + 1 barrel, zero false positives), branch-risk, and
hierarchy; it LOST root-cause (the codegraph agent over-trusted structure and
asserted a wrong cold-start causal chain with high confidence while the grep
agent stayed honest — a cautionary result, not a tool bug: the right answer was
reachable via `path`/`readers`). Verified fixes:

- **`diff --json` and `impact --json` no longer silently drop sections.** Both
  used ONE shared budget consumed in order, so large early sections
  (highInDegree, level-1) starved the decision-relevant later ones to `[]`:
  `diff --json` returned empty `changedButUntested`/`blastRadius`/`providers`/
  `pages`, and `impact --json` reported `summary.files: 306` while `levels`
  listed ~80. Each section/level is now capped INDEPENDENTLY at `--budget`
  (`truncated` set if any exceeds it). On the reference host `diff --json` now
  carries changedButUntested=56, blastRadius=124, providers=150, pages=71.
- **The full changed-but-untested / blast-radius lists are now reachable.** The
  `diff` text sections were hard-capped at 10 and `--budget` didn't expand them.
  The per-section cap now defaults to 10 (compact CI card) but honors `--budget`
  (`--budget 100` shows all 56 untested files); the total-output cap no longer
  re-starves later sections.
- **`impls` is now TRANSITIVE — the full subtype tree, not just direct
  children.** `impls BaseResource` returned only its one direct
  child and hid the 6 concrete leaf cachers (and their mocks) a level deeper —
  false completeness for "list every subclass". It now walks the whole subtype
  closure (a subtype-of-a-subtype is still a stated fact — no guessing),
  cycle-guarded, depth-indented, with `depth`/`supertype` in `--json`.
- **`diff` file counts split `appLib`/`pkgLib`** so `lib` isn't misread as
  app-only in a monorepo (baseline agent discarded all packages/ as "noise" and
  thereby missed a shared theme file, the highest-in-degree changed file).

**Known limitations (documented, deferred — not blocker-class; no wrong edges):**
`find` doesn't index record-typedef FIELDS (`find requiresReauth` → nothing);
no verb gives method-level CALLERS (readers/wiring are provider/file-level), so
"who calls deleteJwt()" still needs grep; the `untested`/`changedButUntested`
list is file-path-granular, so a thin provider wrapper over tested logic reads
as a coverage hole. Boundaries reconfirmed: instantiation-frequency ranking and
runtime "why does X happen" answers legitimately require reading source —
codegraph points AT the files fast (and won branch-risk/hierarchy by doing so).

## 0.8.3 — 2026-07-03 — second A/B eval round: find members + rename-completeness hint

Ran a second with-vs-without-codegraph eval across four new task types (nav-flow
tracing, rename completeness, safe-to-delete, behavioral "why"). codegraph won or
tied on efficiency everywhere and gave no dangerous false positives (`unused`
correctly flagged genuinely-dead files). Two real gaps surfaced, both the same
shape as before — the tool HAD the answer but the verb the agent reached for
didn't surface it:

- **`find` now matches class/extension MEMBERS, not just top-level names.**
  `find handleResume` / `find generateJwt` / `find refreshAfterResume` returned
  nothing even though `skeleton` listed them — only top-level declaration names
  were searchable, so method lookups fell back to grep. `find` now also matches a
  member's declared name (extracted from its signature, so parameter types don't
  produce false hits) and renders it `member: Class.method — file ·N⇐`, ranked by
  in-degree like everything else.
- **`readers`/`provider` on a Notifier-backed provider now appends a
  shape-change hint.** `readers` lists provider CONSUMERS (`ref.watch/read/
  listen`), but a change to the provider's STATE SHAPE also breaks its Notifier
  subclasses and files that use the state type — neither consumes the provider,
  so neither appeared, giving false completeness on a rename (an eval agent had to
  grep to find `MockKeyManagerNotifier extends KeyManagerNotifier`). The hint
  points at the verbs that DO answer it, naming the actual classes read from the
  declaring file: e.g. `readers keyManagerProvider` →
  "Also run: `impls KeyManagerNotifier` · `sym KeyManagerState`."

Both are the recurring lesson: a verb that answers cleanly-but-incompletely must
point the agent to the rest, not let it stop. Boundaries confirmed (not bugs):
`navigates` doesn't model redirect-guard-driven navigation (behavioral), and
"why does X happen" questions still require reading the cache/policy source —
codegraph orients fast, the answer is in the code.

## 0.8.2 — 2026-07-03 — blueprint prompts DEEPER thinking (anti-offloading)

An observation from the A/B eval: on the planning task the codegraph agent got a
complete structural plan in 2 calls but produced a SHALLOWER result than the
grep-only agent, which — forced to read the code — caught the `copyWith` pattern,
the sealed failure taxonomy, the "does this need a new ApiTarget / native
channel?" questions. A tool that answers too cleanly can make the AI stop
thinking. That is the wrong trade for planning, where depth matters most.

`blueprint` now reframes itself from an oracle into a map that DIRECTS deeper
work rather than terminating it:
- **Intent line** changed from "copy this structure" to "a map of the STRUCTURE
  — not a finished plan … Structure is the easy 20%."
- **STUDY THESE** section — the highest-signal files to READ, each with WHAT
  pattern to extract (controller → state orchestration + copyWith; failure/mapper
  → error taxonomy; repository → API contract; page → UI composition; routes →
  registration). Points the agent AT the code instead of replacing reading it.
- **DECISIONS THE GRAPH CAN'T MAKE** section — the judgment calls, TAILORED to
  what the feature actually contains (a `*_platform.dart` → native-bridge
  question; DTOs/repository → backend-contract/ApiTarget question; widgets →
  shared-vs-duplicated; always: runtime behavior, cross-cutting concerns, and
  "why this shape — don't cargo-cult"). Framed as questions (never-guess: asserts
  no fact), so the tool makes the agent stop, read, and DECIDE.
- Both in `--json` (`studyThese`, `decisions`) for the `feature` skill.

Measured (re-ran the planning task on the new blueprint, two agents): with the
SAME prompt and 2 calls, the agent now produces a DECISION-AWARE plan flagging
the exact judgment calls it previously missed (native channel, backend contract,
shared-vs-duplicated UI, bearer injection) — false completeness replaced by
targeted known-unknowns. When the agent engages the STUDY-THESE files it reaches
depth BEYOND the grep-only baseline: it caught the controller's re-entrancy
`Completer` guard, the optimistic-cache-then-refresh UX pattern, why it's a single
imperative `AsyncNotifier` (not split providers), and the load-bearing ambiguity
of whether the new feature is OAuth-authority vs OAuth-client ("a fork in
the road, not a detail"). The tool now directs saved search-budget INTO deeper
thinking rather than terminating it. Honest limit: it makes the agent AWARE the
depth is needed and points at exactly where; it does not FORCE the reading — a
fast agent still flags-and-defers.

## 0.8.1 — 2026-07-03 — eval-driven completeness fixes

Found by an A/B evaluation: three realistic production-host tasks run by paired agents,
one forbidden from codegraph (grep only), one told to use it. codegraph won
decisively on transitive impact (3 calls / correct vs 6 calls / wrong) and on
planning (2 calls for a complete build plan), but LOST the "list every reader"
task — which exposed a real under-reporting bug.

- **Field-held `Ref` receivers are now detected.** Provider `watch`/`read`/
  `listen` edges were only recorded when the receiver was a local `ref` /
  `this.ref`. Classes that hold the Ref in a FIELD — `_ref.read(jwtProvider)`,
  the norm for interceptors, services, coordinators, notifiers — were SILENTLY
  MISSED, so `readers`/`impact`/`wiring`/`blueprint` under-reported. Now
  `_ref` / `this._ref` / `widgetRef` / `this.widgetRef` are recognized too (the
  arg still resolves to a real provider downstream, so this adds real edges, not
  guesses — verified: 488 of 490 reads resolve to a declared provider node, zero
  new garbage). On the reference host: +50 real read edges (+4.9%); `readers jwtProvider`
  went from 18 to 23, now correctly including the HTTP interceptor and the router
  redirect facts that read via `_ref`.
- **`blueprint`'s EXTERNAL SEAM is now comprehensive.** It was derived only from
  the feature's declared providers' deps, so a cross-area provider read by a
  PAGE or WIDGET (a non-provider file) was missing from the seam a new feature
  must wire to. Now it scans every file in the feature (like brief's cross-area
  computation): `blueprint lib/features/sign_in_with_oauth` seam went from 3 to
  6, now including `jwtProvider` / `selfCacheProvider` / `profileCacheKeyProvider`
  (read by the authorization page).

## 0.8.0 — 2026-07-03 — "Upgrade & Plan"

Re-scoped from the original CI-leverage plan (affected-tests / risk — deferred to
0.9.0) toward what the tool is actually FOR on its primary host: help an AI
understand, navigate, and PLAN — and close the missing upgrade story. Both
features were dogfooded on the reference host before shipping.

- **The upgrade story.** The graph already auto-migrates (gitignored, rebuilt
  every session by the hook / in CI by `check`; format skew handled by
  `Graph.load`). But the generated SCAFFOLDING (skill, CLAUDE.md block, hook,
  cursor rule, CI workflow) was written ONCE by `init` (which skips existing
  files) and never refreshed — so new verbs never reached a host that ran `init`
  at an older version, and nothing told the AI its skill/command-list was stale.
  Now:
  - Every generated artifact is **version-stamped** (CLAUDE marker
    `<!-- codegraph:begin vX.Y.Z -->`, `# codegraph-scaffold: vX.Y.Z` in
    hook/cursor/workflow, an HTML comment in the skill). Marker detection is
    **whole-line-anchored**, so a CLAUDE.md that merely documents the markers in
    prose is never mistaken for an installed block.
  - **`codegraph upgrade`** refreshes the codegraph-OWNED files in place (hook,
    skill; cursor rule + workflow only if already present) and replaces the
    CLAUDE.md block strictly BETWEEN its markers — preserving every byte outside.
    It NEVER touches `.claude/settings.json`, `LIMITATIONS.md`, `codegraph.json`,
    `notes/`, or the graph. Idempotent; refuses safely on a malformed
    (begin-without-end) block.
  - **`doctor` + `passport` nudge** when the scaffold stamp is behind the binary
    (or unparseable — never-guess). The passport nudge prints at session start
    even when the graph is absent (a fresh host is exactly when a stale scaffold
    matters), so the AI is TOLD to run `codegraph upgrade`. `version_skew.dart`
    is the single source of truth for the binary version.
- **`codegraph blueprint <feature>` — the planning primitive.** `brief` ranks a
  feature's current state by importance (understanding); `blueprint` gives the
  build-order TEMPLATE to CREATE an analogous feature — the gap that made
  the host project's whole `feature` skill "copy `sign_in_with_oauth/`". Six
  graph-derived sections: **LAYERS** (files grouped by intra-feature dir —
  `domain → data → application → presentation → routing`, the build order brief
  can't see; role-rank fallback for flat features — each with role + declared
  symbols); **PROVIDER WIRING** (each provider's watch/read/listen deps split
  INTERNAL vs EXTERNAL — the reusable dependency pattern; grouped by declaring
  file so a multi-provider file's deps are shown file-level, never fabricated
  onto a specific provider); **EXTERNAL SEAM** (cross-area providers to wire to);
  **ROUTES**; **NAMING CONVENTIONS** (observed suffix + provider-name template);
  **TESTS** (coverage + gaps). Never-guess: reports only structure the graph
  states — no invented files/layers, and watch-edge attribution that can't be
  split per-provider is DISCLOSED as file-granular, not asserted. text +
  `--json` (for the `feature` skill); deterministic. Dogfooded on
  `lib/features/sign_in_with_oauth`: hands an agent the layer scaffold, the
  provider topology, the external seams, the naming template, and the coverage
  gaps — enough to build an analogous feature.
- Adversarial review (Opus) caught + fixed pre-ship: a blueprint wrong-edge
  (a sibling provider's dep fabricated onto a cookie-jar provider) and an
  `upgrade` path that could rewrite user prose mentioning the markers.

**Deferred to 0.9.0** (were the original 0.8.0): `affected-tests` / `risk` / CI
test-selection (CI-leverage, not the primary understand/plan job); `tests <thing>`
reverse index; Riverpod cycle / god-provider lint rules — add on the 0.7.0 lint
engine when there's a real ask.

## 0.7.0 — 2026-07-03 — "Lint"

The graph becomes PRESCRIPTIVE. Host repos state architecture rules in prose that
nothing enforced (the host's AGENTS.md non-negotiables are the motivating case);
`codegraph lint` turns them into a CI gate that catches agent drift mechanically,
before human review — with a baseline ratchet so adopting on a repo with existing
violations is one command, not a cleanup project.

- **`codegraph lint`** (`lib/src/lint.dart`) — config `codegraph.json` at the host
  root (stdlib `jsonDecode`, zero new deps; absent → conservative defaults;
  unknown keys → one warning; malformed → exit 64). Rules are plain
  `List<Violation> Function(Graph, LintConfig)`, never a framework. **Never-guess
  is the whole game here: a rule fires ONLY on a fact the graph states** (an
  import edge, a role, a provider kind) — nothing heuristic, and every rule ships
  a firing test AND a non-firing near-miss.
  1. **cross-feature-import** — an import crossing two units under a `features/`
     prefix (default `lib/features/`; a file directly under the prefix has no unit
     — never invented). `crossFeatureAllow` exempts `"a -> b"` pairs. Feature
     prefixes are normalized to a trailing `/` so `startsWith` matching is
     segment-safe (can't straddle `lib/features_experimental/`).
  2. **layer-order** — an import whose `srcRole -> dstRole` is in `layersForbid`
     (defaults: `repository`/`state/model` → `view`/`widget`/`controller`).
     Carries the import `file:line`.
  3. **banned-provider-kind** — a provider node whose kind is in
     `banned_provider_kinds` (default `[]`). Identity is per-provider
     (`file|name: Kind`) so multiple banned providers in one file don't collapse
     to a single baseline entry.
  4. **provider-placement** — a `declares` edge whose src file role isn't in
     `provider_homes` (default absent = rule OFF; unset means "no opinion", not
     "empty allow").
  Text + `--json` (total-budgeted, `truncated`) render; exit **0** clean-or-all-
  baselined / **1** new violations / **66** no graph / **64** malformed config.
- **Baseline ratchet** — `lint --write-baseline` writes `docs/maps/lint-baseline.json`
  (`{version, violations:[sorted "rule|from|to"]}`, identity carries NO line so
  moving code never churns it, byte-deterministic). Plain `lint` then fails only
  on violations NOT in the baseline; fixed ones print a stale-entry note (never
  affects exit). `build` never writes the baseline, so `check()` sees no drift. A
  malformed/merge-conflicted baseline is a clean exit 64, never a stack trace.
- **`imports` edges gain `line`** (the wire addition deferred out of 0.6.0):
  `FileInfo.importLines` captures each import/export/part directive's line via
  `unit.lineInfo` (first-occurrence wins). `stats.format` 3 → **4**. Purely
  additive — on the reference host, nodes identical and every edge unchanged
  except imports edges gaining `line`.
- **Integration:** the diff card appends `lint: N new architecture violation(s)`
  when new violations exist in the working tree (verb-only, crash-safe); the
  `init --ci` workflow gains a lint step (with a baseline-first bootstrap comment);
  `init` prints a starter-config NOTE when `codegraph.json` is absent and
  `lib/features/` exists; the CLAUDE.md/skill/cursor command block gains a `lint`
  line; `doctor` notes a malformed `codegraph.json` (absent is normal).

**KNOWN LIMITATION (documented, not a bug):** `layer-order` and `provider-placement`
ride the graph's `role` field, which is a coarse path/filename heuristic
(`*_repository.dart` → repository, `/model/` → state/model, `*_page.dart` → view).
A mis-named file (a helper `*_repository.dart` that isn't a data repo) can produce
a confident-but-wrong violation. The role is a STATED fact the rule reads (not a
per-rule guess), and the baseline ratchet absorbs existing cases so only NEW
violations fire — but adopters should expect the occasional false positive and
allow-list it via the baseline. Rule 3 also only sees provider kinds the engine
emits as provider nodes (the full-word `AutoDisposeStateProvider` spelling isn't
detected — the `.autoDispose` modifier form IS).

**reference host profile** (config: `features: ["lib/features/"]`, banned kinds =
Standard 03's `StateProvider`/`StateNotifierProvider`/`ChangeNotifierProvider`):
**1 total violation** — 0 cross-feature-import, 1 layer-order (a genuine
`model/` → `view/` smell), **0 banned-provider-kind** (real compliance: 243
providers, none of the banned kinds — all `NotifierProvider`), 0 provider-placement.
The repo is already clean against these rules; lint's value here is preventing
drift, not clearing a backlog.

## 0.6.0 — 2026-07-03 — "Trust"

Close the gaps that made agents and humans hedge — ambiguous nav silence,
token-match testRefs, oversold README — and delete the artifact weight that no
longer earned its churn. Every change is a precision or honesty fix; nothing
guessed.

- **Nav gaps are legible, not silent.** `navigates` edges gain an additive
  `unresolved: true` flag (present exactly when no resolved `navigates-to`
  sibling exists — set at emission from `pageFile == null`). `wiring`/`brief`
  now render navigation inline: `'/details':12 → lib/x/details_page.dart` when
  resolved, `AppPaths.foo.path:34 (unresolved)` when not (the separate
  `navigates-to` text section is dropped; `path` traversal still uses the
  edges). `passport` gains `nav: N/M resolved`. The renders are
  **flag-authoritative** and refuse to guess a target when two navigations
  share one source line (adversarial review caught the line-only join
  mislabeling the unresolved call with the resolved call's target — the exact
  wrong-edge class this release exists to prevent; fixed in `navLines` and
  ATTENTION before ship).
- **testRefs precision — registry resolution replaces bare tokens.** A provider
  name in a test file now credits `testRefs` only when a declaration of that
  provider is in the test file's import+export closure (a name in a comment no
  longer counts unless its declaring file is actually reachable). Root-cause
  follow-on from review: `part` files carry no import directives of their own —
  a library's imports live in the library file — so a provider referenced
  (`.overrideWith`) inside a `part`-file integration harness was wrongly read
  as untested. Fixed: a `part` file inherits its parent library's imports (URI
  `part of 'x.dart';` only; by-name `part of` is not inherited — never guess).
  This also repairs the same pre-existing blind spot in `fileTestRefs`. On the
  reference host: zero net regression (all 13 harness-covered providers the raw
  gate dropped are restored), mechanism now closure-gated + part-aware for
  0.8.0 affected-tests.
- **Maps slimmed to Summary-only.** Area `.md` maps now render title + `##
  Summary` + a one-line `Full detail: codegraph brief <area>` pointer.
  `brief`/`wiring` supersede the old per-map wiring tables and file inventories,
  which were the bulk of per-PR commit churn (auth.md 7627→1302 chars; churn per
  code change drops ~10×). The oversized-map splitting machinery
  (`splitThresholdChars`, `splitDecision`, `_writeSplitAreaMap`, sub-map
  rendering) is deleted — a Summary-only map can't exceed the old threshold.
  Hosts remove stale `<area>-<sub>.md` once at rollout (`build` doesn't delete
  unknown files). The markdown/INDEX writers moved out of `engine.dart` into
  `lib/src/markdown.dart` (engine 1509→1150 lines). The graph is byte-identical
  across this change — maps only.
- **`codegraph doctor`** — read-only install health (`--json`, exit 1 on any
  fail): graph present, binary-vs-graph `format` skew, hook installed + wired
  under `hooks.SessionStart` (JSON-parsed, not a substring match), `.gitignore`
  entry + JSON untracked, CLAUDE.md marker + skill present, CI workflow
  (note-level), package-root == git-root (note + monorepo guidance). Kills the
  silently-broken-install class.
- **Monorepo hook self-location.** The generated SessionStart hook, when
  `$CLAUDE_PROJECT_DIR` has no `pubspec.yaml`, probes one directory level for a
  subdir with both `pubspec.yaml` and `docs/maps/` and cd's there (sorted first
  match; none → `exit 0`, fail-safe). Single-package path byte-unchanged. `init`
  prints root-settings guidance when run from a package root that isn't the git
  root.
- **Wire format:** `stats` gains a first key `format: 3`; `Graph.load()` prints
  one stderr note (never fails) when the on-disk `format` is missing (pre-0.6)
  or newer than the binary — the cross-machine stale-binary tell.
- **README honesty:** deep value is Riverpod + GoRouter (provider wiring, nav
  resolution, readers); imports/types/symbols/tests work everywhere. The
  code-map skill description no longer advertises the Stage-2-deleted map
  sections.
- **Cleanup:** one `Budget`, one `joinCapped`, one `inDegSuffix`, one `bare` in
  `cli_util.dart` (deleted the query/brief/diff/impact copies; output
  byte-identical).

**DEFERRED to 0.7.0:** the pinned `line` key on `imports` edges (0.7.0 lint's
file:line output needs it; capturing import-directive lines means threading line
numbers through `FileInfo.internalImports`, so it lands as 0.7.0 Stage 1's first
task with a `format: 4` bump, not retrofitted here).

## 0.5.0 — 2026-07-03

Navigation-resolution uplift: 26/100 → 39/100 navigate edges resolved on the
reference host, with zero wrong edges — every new mechanism ships with an
explicit refusal gate and a test proving the refusal.

- **Mechanism (a) — route-constant substitution:** top-level vars and static
  fields whose initializer is an `AppPaths.`-rooted chain are recorded; a nav
  expression (or GoRoute `path:`) whose leading identifier names such a
  constant is substituted and re-normalized (fixpoint, depth cap 3,
  cycle-guarded). GATES: the constant's declaring file must be
  import/export-reachable from the substituting file (shared `_Reachability`
  BFS, factored out of the provider resolver); the substituting file must not
  itself declare that identifier anywhere — locals and parameters included —
  (shadowing guard, via a new per-file declared-names pass); and exactly one
  distinct declaration may be reachable (two same-name constants both
  reachable → refuse).
- **Mechanism (b) — monomorphic helper inlining:** a function whose GoRoute
  uses a parameter as `path:` is inlined from its call site. GATES: exactly
  one DECLARATION with that function name project-wide; exactly one
  invocation call site; positional args only; and a tear-off guard — the name
  may not be referenced in any file beyond the declarer and the single caller
  (per-file identifier-reference pass; same-file tear-offs remain
  undetectable at file granularity and are documented as the residual).
- **Mechanism (c) — library wrapper allowlist + goNamed:** builders wrapped
  in exactly {MaterialPage, CupertinoPage, NoTransitionPage,
  CustomTransitionPage, ModalSheetPage} resolve through their `child:`
  argument (unwrapping only through allowlisted types, depth cap 3;
  project-declared wrappers keep refusing). `goNamed('x')` matches
  `GoRoute(name: 'x')` by exact string; a name declared by more than one
  GoRoute is dropped (refuse, not first-wins).
- Adversarial review confirmed three wrong-edge blockers in the first draft
  (bare-text matching with no scope/import/declaration identity — local
  shadowing, cross-file same-name merging, call-site bucketing by name) —
  all fixed with the gates above before release; the metric was unchanged by
  the gates (39/100), confirming no correct edge depended on unsafe matching.
- Build-time cost of the new identity passes: ~0.2-0.3s on a 1569-file host.

## 0.4.1 — 2026-07-02

Correctness patches to 0.4.0's review verbs.

- **Fix: `diff` now sees untracked files.** `git diff <ref>` is blind to
  files never added to git, so a brand-new uncommitted provider was invisible
  in the card. The changed set now merges `git ls-files --others
  --exclude-standard` (gitignored artifacts stay excluded by construction);
  untracked dart files appear as additions in every section including
  `changed but untested`.
- **Fix: testRefs follows export closures.** A test importing an export-only
  barrel used to credit the barrel and leave the re-exported implementation
  file at zero. Test-reference crediting now walks the transitive export
  closure of each directly-imported file (cycle-guarded, memoized) — exports
  are exactly what re-expose symbols, so this is precise, not a heuristic.
  Provider crediting (token matching) is unchanged and remains candidate
  data.

## 0.4.0 — 2026-07-02

The review release — test-reference pass, transitive-impact verbs, branch
blast-radius card, and navigation-resolution prototype.

- **Stage 1 — test references + `untested` verb:** Engine scans test roots
  (test/, integration_test/, patrol_test/) and tokenizes each test file to
  count provider name matches and file imports. Emits testRefs counts on
  provider and file nodes (omitted when 0); stats gains testFiles. New `untested`
  verb lists providers/files with zero test references (ranked by in-degree).
  `unused` verb adds ` · test-only (N test refs)` suffix to entries that ARE
  referenced from tests (kills false positives). Wire-format additions at pinned
  positions (testRefs fields, testFiles stat).

- **Stage 2 — `impact` verb + multi-term `find`:** New `impact <thing> [--depth N]`
  (default depth 2, max 5) computes transitive dependents via BFS: shows all
  files and pages that read/watch/listen to a provider or import a file, and
  recursively, their consumers. Example: `impact homeProvider` shows 8 files
  that read it. Exported `dependentsOf()` function for Stage 3 reuse. `find`
  now accepts multiple terms (`find fancy button` finds FancyButton); each term
  must match a token in the name/path. Single-term behavior byte-identical to
  0.3.x.

- **Stage 3 — `diff` verb + PR-comment CI step:** New `diff [--base <ref>]`
  shows an 8-section branch blast-radius card: files changed (count), areas
  touched, high in-degree changes (risk list), providers added/modified (with
  reader counts), pages changed, deleted-but-still-imported files
  (broken-import candidates), changed untested code, and blast radius (depth 1
  dependents of all changes). Respects --budget and --json. CI template
  (init --ci) gains a PR-comment step: posts the diff card to every PR.
  git-optional (ProcessException → one-line error, not crash).

- **Stage 4 — navigation resolution (prototype; allowed to fail):** Engine
  second-pass matches `AppPaths.`-rooted navigation expressions to GoRoute
  declarations and resolves the builder's page type via the class registry
  (partial; unresolved edges stay raw — local-variable destinations and
  cross-function route indirection are out of syntax-only scope and are
  NEVER guessed). Emits navigates-to edges (in addition to raw navigates) at
  the pinned position; wiring/brief/path surface them. Build stderr metric:
  `nav resolution: X/Y navigate edges resolved` — measured 26/100 on the
  reference host at release. Known follow-up: top-level route-constant
  variable substitution (e.g. `final r = AppPaths.a.b;` then `r.path`) is
  statically visible and would cover most of the unresolved set.

- **Deferred (unchanged):** PageRank map, fold levels, slice, locate remain
  gated.

- **Version:** 0.3.1 → 0.4.0. bin/codegraph.dart usage and CLAUDE.md
  _commandBlock updated with diff/impact; _skill body updated with untested
  mention.

## 0.3.1 — 2026-07-02

Cruft purge, prompted by a "what's useless in here?" audit.

- **Purged: the repo's own committed `docs/maps/`.** It violated 0.3.0's own
  don't-commit-the-JSON policy, was stale (still showed the `_providerKinds`
  false positive 0.3.0 fixed), and — because `docs/` is the GitHub Pages
  root — was being published on the website. Now gitignored for this repo.
- **Merged: the legacy `FileInfo.classNames/enums/functions` lists into
  `symbolRecs`.** They survived 0.2.0 only to feed the markdown inventory
  column; that column now derives from symbol records (source order, and
  extensions/extension types/typedefs finally appear in it — they were
  silently missing). Three parallel data structures deleted.
- **Purged: `ClassDecl.isInterface`** — computed and stored, never read.
- **Merged: byte-identical duplicate `_emit`/`_intFlag` helpers** (query.dart
  vs brief.dart) into `cli_util.dart` — one definition of the line-budget
  output contract.
- **Merged: the wiring destination display-name logic** (duplicated in
  query.dart and brief.dart) into `GraphEdge.dstDisplayName` on the model,
  next to the ambiguity sentinel it renders.
- **Kept deliberately:** the `provider` verb alias (0.1.2 recorded decision)
  and the committed `pubspec.lock` (CLI-app convention).

## 0.3.0 — 2026-07-02

Typed graph model, human reviewer surface, knowledge sidecar, and docs. Paydown
of structural debt (untyped maps), migrate artifacts to git-safe strategy (stop
committing 3.7 MB JSON), add deterministic triage document (ATTENTION.md), and
widen init to Cursor.

- **Stage 1 — typed graph model** (`lib/src/model.dart`): Extract untyped-map
  field patterns into `GraphNode`, `GraphEdge`, and `Graph` classes. Wire format
  frozen byte-identically (single test confirms round-trip). Kills the
  untyped-map field-drop bug class: field access now goes through typed
  properties, errors caught at compile time, not runtime.
- **Stage 2.1 — stop committing code_graph.json:** `init` adds
  `docs/maps/code_graph.json` to `.gitignore` (idempotent). Migration hint on
  upgrade: if tracked, user sees a NOTE to `git rm --cached` it. `check()`
  unchanged — untracked files never diff anyway.
- **Stage 2.2 — ATTENTION.md + attention verb:** `build` writes
  `docs/maps/ATTENTION.md`, a deterministic triage doc with five sorted sections
  (capped 20 entries each): ambiguous providers (>1 declaration with reader
  count), zero-consumer providers, orphan files, duplicate symbol names
  (class/enum declared 2+ times), unresolved navigation edges (route
  indirections). `codegraph attention` verb recomputes and adds a verb-only
  section: "Possibly stale notes" (git staleness vs area, only when notes exist
  and git is available).
- **Stage 3 — knowledge sidecar `docs/maps/notes/`:** Ungated, hand/AI-authored
  markdown excluded from build writes and `check()` diffs. Convention:
  `docs/maps/notes/<area-name>.md`. Surfaced in `brief <area>` (first 20 lines
  + "… N more" if longer), in `passport` (one line listing non-empty areas), and
  staleness-checked by `attention`. Never generated, never rewritten — the safe
  form of "AI writes context."
- **Stage 4.1 — Cursor support in init:** If `.cursor/` exists in the host (or
  `--cursor` flag passed), write `.cursor/rules/codegraph.mdc` (skip if exists)
  with the same brief-first command list.
- **Stage 4.2 — docs:** README adds `## --json output` section (envelope shape,
  one example, per-verb support list); Install caveat about invoking the binary
  directly (pub resolution corruption); Freshness section expanded to cover
  committed vs untracked artifacts (markdown maps, .gitignore the JSON, notes/,
  ATTENTION.md); Query list adds `passport` and `attention`. `bin/codegraph.dart`
  version → 0.3.0, usage already has `attention`. `lib/src/engine.dart` header:
  one decision line (0.3.0: typed model, untracked JSON, ungated notes).
- **Stage 4.3 — determinism lock test:** New test: build fixture, hash every
  file under `docs/maps/` except `notes/`, build again, assert byte-identical.
- **Stage 4.4 — landing page sync:** `docs/index.html` hero terminal adds a
  `brief` exchange; "Eight verbs" → "Thirteen verbs" with `brief`, `sym`,
  `skeleton`, `passport`, `attention` added as cards; quickstart step 3
  mentions passport.

### Rejected / deferred (do not re-propose without a new trigger)

- **AGENTS.md auto-append:** codegraph init could append to AGENTS.md when it
  exists, but double-injection risk when AGENTS.md imports CLAUDE.md. Skip;
  revisit on request.
- **Windows PowerShell hook:** porting the SessionStart hook to Windows PowerShell
  is a gap, not a rejection. macOS/Linux only for now; a future PR can add
  PowerShell support.

## 0.2.0 — 2026-07-02

Cut agent understanding-time from ~25–35k tokens per feature to ~9–12k by:
storing signatures + line numbers with symbols, adding one-shot composition
verbs, emitting a session passport (~450 tokens), and fixing oversized
markdown artifacts.

- **Stage 1 — symbol records + line numbers (engine.dart):** FileInfo now
  emits symbol records with kind, line, signature (rendered from AST,
  truncated to 140 chars), doc (first line, 100 chars), and members
  (PUBLIC only, max 12, formatted `line: sig`). Wiring edges (watches/reads/
  listens/navigates) and provider nodes now carry line numbers (the line
  where the edge appears in the source file, or the provider's declaration
  line). Legacy symbol-name lists still present for markdown backward
  compatibility.
- **Stage 2 — query verbs (query.dart, skeleton.dart):** (a) `sym <Name>`
  prints a symbol card: signature, doc, line in file, members, and imported-by
  count. (b) `skeleton <file>` prints a per-file outline (all declarations
  including private ones, line numbers, no need to Read the file). (c) `find`
  now ranks results by in-degree (imports for files, watches/reads/listens
  for providers) with a ` ·N⇐` suffix. (d) Symbol hits now include `:line`.
  (e) `--json` flag added to find/readers/wiring/impls/sym (machine-readable).
  (f) `_emit` hints when output is truncated (`raise --budget N` or
  `narrow the substring`).
- **Stage 3 — brief + passport (brief.dart):** (a) `brief <thing>` resolution
  order: exact provider name → PROVIDER brief (readers + declaring-file brief);
  area prefix → AREA brief (top files by in-degree, top providers by readers,
  entry pages, cross-area imports); unique file substring → FILE brief (wiring
  + symbols inline + edge line numbers); exact symbol name → FILE brief +
  symbol card at the top; else → no match. (b) `passport` prints a ~40-line
  session digest (project name/counts, top areas/files/providers, verbs).
- **Stage 4 — markdown + templates (engine.dart markdown, init.dart):** (a)
  Area maps now ship with a Summary section (counts, top providers by readers,
  entry pages, cross-area providers). (b) Oversized maps (>20k chars) split by
  path segment into sub-maps + parent summary + links. (c) File inventory
  symbols cell capped at 4 (was 6). (d) INDEX.md token column added (~chars/4,
  rounded to 100). (e) Hook template: after freshness check, emit `passport` or
  fall back to `echo "code graph fresh…"`; second line echoes `relationship
  questions → codegraph brief|find|sym|skeleton|wiring|readers`. (f) CLAUDE.md
  block: command list reordered to lead with `brief`, adding `sym` + `skeleton`
  lines. (g) Skill template: targeted-questions block adds `brief/sym/skeleton`
  + "start with `brief`" guidance.
- **Version:** 0.1.2 → 0.2.0.

### Rejected (do not re-propose without a new trigger)

- **MCP server mode:** MCP tool schemas cost tens of thousands of resident
  context tokens per session vs ~50 tokens per Bash CLI call — keep this a
  CLI. Revisit only with evidence the per-call cost exceeds the resident
  overhead.
- **LLM-generated summaries at build time:** nondeterministic output breaks
  the `check()` CI gate's content-diffing guarantee.
- **Git-churn counts in committed artifacts:** time-varying values (commit
  count, churn in the last N days) break determinism as the measurement window
  moves.
- **2k-token session-start map injection:** the ~450-token `passport` covers
  orientation; a larger injection bloats every session.
- **Per-edit (PostToolUse) impact echo:** the per-edit hook direction is
  already rejected (latency tax on every edit), and the echoed graph would be
  stale with respect to the very edit that triggered it — misinformation at
  the worst moment.

## 0.1.2 — 2026-07-02

Structural follow-up to 0.1.1, caught by an independent review of that
diff. No behavior change beyond one cosmetic display fix (last item).

- **Refactor: extracted `_ProviderResolver`.** 0.1.1's duplicate-name fix
  landed as five moving parts (`ambiguousNames`, an `importGraph` index, a
  `reachCache`, a `reachableFrom` traversal, and a three-way branch) inlined
  directly into `_writeGraph`, nested inside a per-file loop, inside a
  closure — a reader had to hold "how do I emit a node" and "how do I
  disambiguate a shared name" in mind at once to follow any of it.
  `_ProviderResolver` (`lib/src/engine.dart`) now owns that concept end to
  end (`nodeIdFor`, `edgeFieldsFor`, the reachability cache); `_writeGraph`
  builds one instance and calls it, back to roughly its pre-0.1.1 size and
  flatness. Considered always suffixing every provider id by file to drop
  the ambiguous/unambiguous branch entirely — rejected: it breaks the
  zero-shape-change-for-unique-names guarantee 0.1.1 was built around, and
  callers key off `provider:name`. The resolver gets the simplification
  without that cost.
- **Fix: "is this name ambiguous" was computed twice, independently.**
  `build()` derived `providerRegistry` via `length == 1` on
  `providerDeclsByName`; `_writeGraph` separately derived `ambiguousNames`
  via `length > 1` on the same map — the same predicate, negated, written in
  two places with nothing tying them together. Both now read
  `resolver.ambiguousNames` off one `_ProviderResolver` instance built once
  in `build()`.
- **Not changed, and why:** an edge referencing a provider can be shaped four
  ways (plain / external / disambiguated / ambiguous-unresolved) inside the
  still-untyped `Map<String, dynamic>` node/edge model, and `query.dart`
  hand-matches the "unresolved" sentinel (`dst == 'provider:$name' &&
  ambiguous == true`) rather than sharing a type with the producer. Left
  alone on purpose — untyped JSON literals are this project's established
  style (see the `Resolved-AST analysis` rejection below), and a sealed
  `ProviderEdge` model is overkill for four variants in a two-file tool.
  Noted inline at the one call site that depends on the convention; revisit
  if the edge schema grows more variants than that.
- **Fix: dead `full` parameter removed.** `query.dart`'s
  `_readers(rest, budget, {bool full = false})` never read `full` — a
  pre-existing no-op that predates 0.1.1, left behind when that diff
  rewrote the whole function instead of resolving it. `readers` and
  `provider` are genuinely identical output today; `provider` stays as a
  separate documented verb (reads better when starting from "what is this
  provider" instead of "who reads it"), the fake per-command flag is gone.
- **Fix (cosmetic): `wiring`'s display for an ambiguous provider.** Used to
  inline the full disambiguated id
  (`visibleCurrenciesProvider@lib/features/home/.../home_controller.dart`) —
  correct but the noisiest line in an otherwise compact command. Now shows
  `visibleCurrenciesProvider (ambiguous, see readers)` and points at the
  command that has the detail.

## 0.1.1 — 2026-07-02

- **Added:** a GitHub Pages landing site (`docs/index.html`, single-file,
  no build step).
- **Fix:** test suite raced on the process-global `Directory.current` under
  `package:test`'s default concurrent execution — each test spins up its own
  temp fixture project and chdirs into it, so a concurrent test could commit
  git fixtures into another test's directory. Pinned `concurrency: 1` in
  `dart_test.yaml`; the suite is 4 fast tests, parallelism isn't worth the
  flakiness.
- **Fix:** `init`'s `_wireSettings()` spliced an unescaped `"` into the
  `.claude/settings.json` JSON template, producing invalid JSON on every
  `codegraph init` run (caught installing into a nested-package monorepo
  where the Dart package root isn't the git repo root — the JSON error
  otherwise silently defeats the SessionStart hook everywhere). Escaped as
  `\\"` in the Dart source so the emitted JSON is valid.
- **Fix: duplicate provider names no longer silently merge onto one wrong
  declaration.** `providerRegistry[p.name] = p` was last-write-wins — two
  providers sharing a name (e.g. `visibleCurrenciesProvider` declared once
  per feature) collapsed into ONE node keyed by name, and every reader of
  either declaration got attributed to whichever file happened to be
  processed last alphabetically (confirmed on a nested-package host: readers of the
  `currencies` feature's declaration were reported as reading the `home`
  feature's declaration instead). Now: every declaration gets its own node
  (`provider:name@file` when the name is ambiguous, unchanged plain
  `provider:name` otherwise — zero shape change for the 99% non-duplicate
  case), and each reader is resolved to the specific declaration it can
  actually reach via the already-collected import/export/part graph. If
  reachability can't narrow it to exactly one candidate, the edge is flagged
  `ambiguous: true` with all candidates listed rather than guessing — a loud
  "can't tell" beats a silent wrong answer. `readers`/`provider` now report
  each declaration's consumers separately with a header naming the ambiguity,
  and `find` now surfaces both declarations instead of only the last one
  registered. `unused` also got more precise as a side effect: a genuinely-
  used ambiguous declaration can no longer be masked by the other
  declaration's edges landing on the same merged node.
- **Fix: `check()` (the CI freshness gate) embedded a wall-clock timestamp in
  the exact files it content-diffs, so it failed on every real CI run
  regardless of drift.** `code_graph.json`'s `generatedAt` and each markdown
  map's `_Generated ... at $ts_` line changed on every `build()`, so a commit
  made at T1 checked by CI at T2 (T1 ≠ T2, essentially always true in
  practice) always showed a diff on that one line — `check()` reported STALE
  unconditionally, defeating its only purpose. Reproduced directly (build,
  commit, sleep past the second boundary, `check()` → always failed) and
  confirmed the fix the same way (now passes). Found while regression-testing
  the duplicate-provider fix above: extra work per `build()` made local
  build-then-check test sequences cross a second boundary often enough to
  fail intermittently, which is what surfaced the always-broken-in-CI case.
  Dropped both timestamps outright — git history already answers "when was
  this generated," and a field whose entire job is content-equality checking
  must not contain the one thing guaranteed to differ between two correct
  builds.
- **Known limitation, not fixed here (host-project workaround instead):**
  `init`'s hook assumes `$CLAUDE_PROJECT_DIR` (the Claude Code project root)
  equals the Dart package root (cwd when `init` ran). True for single-package
  repos; false for monorepos where the package lives in a subdirectory (e.g.
  `app/`). In that case the generated hook script's `cd` also needs to
  self-locate instead of trusting `$CLAUDE_PROJECT_DIR`, and the operator
  needs a root-level `.claude/settings.json` wired to
  `app/.claude/hooks/code-graph-refresh.sh` (nested `.claude/settings.json`
  files aren't read by the harness — only the project-root one is; this
  differs from skills, which are discovered anywhere in the tree). Left as a
  manual per-monorepo step rather than adding path-detection to `init`;
  revisit if this comes up in a second monorepo.

## 0.1.0 — 2026-07-02

Initial public release.

- Single binary, verbs: `build`, `check`, `init [--ci]`, `find`, `readers`,
  `provider`, `wiring`, `impls`, `path`, `unused`.
- Analyzer-based extraction (Riverpod provider declarations and
  `ref.watch/read/listen` edges, GoRouter navigation targets, the
  extends/implements type graph, import/export/part edges including
  conditional configurations, per-file symbols) — resolved against a
  whole-project registry, so e.g. a provider is one canonical node instead of
  fragmenting per reader.
- Host package name read from `pubspec.yaml`; local packages under
  `packages/*/lib` auto-discovered from their own pubspecs — works on any
  Dart/Flutter project unchanged, no project-specific configuration.
- `init` installs the agent trigger layer: a marker-guarded `CLAUDE.md` block,
  a fail-safe SessionStart hook, a prompt-shaped `code-map` skill, a
  `LIMITATIONS.md` seed for the self-correcting loop, and an optional CI
  freshness gate.
- Parses syntax only (no resolved element model), so it needs no `pub get` in
  the host project and never breaks on unresolvable or private dependencies.

### Rejected (do not re-propose without a new trigger)

- **Per-edit (PostToolUse) regen hook** — seconds of latency on every edit for
  marginal freshness. A SessionStart check-then-regen plus a CI gate cover the
  freshness need without that cost.
- **Tree-sitter extraction** — a syntactic (non-resolving) tree-sitter pass
  fragments providers into one node per reader (breaking "who reads X?") and
  misses framework navigation calls that require type resolution.
- **Resolved-AST analysis (full element model)** — would require the host
  project's `pub get` to succeed (breaking in CI on private/git dependencies)
  and costs 10-100x the runtime, for relationship questions that syntax-level
  parsing plus name registries already answer correctly.
