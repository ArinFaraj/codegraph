# codegraph v4: rewrite plan

Status: implemented in 4.0.0 (2026-10-19). Building it corrected three
things in this plan; they are marked "Corrected in 4.0.0" where they occur:
the analysis-context count, sharing the analyzer cache, and the pub-workspace
suggestion. Typed route topology was deferred.

Originally written as a proposal on 2026-10-19. It is based on reading the engine (v3.9.0) end
to end, running every command against krdpass-app, reading 163 past agent
sessions in that repo, and five spikes run against an exported snapshot of
krdpass-app in `/tmp` (section 1.5). krdpass-app is the only consumer, so v4
breaks compatibility freely. Nothing old survives unless it earns its place
below.

## The core rethink, in short

codegraph today is three products bolted together. It is a docs generator (the
committed `docs/maps/`), a CI gate (map freshness, the lint baseline, a PR bot),
and a query and refactor tool. Nearly all of the pain comes from the first two.
Nearly all of the value comes from the third. And the third is weakest exactly
where it claims to be strongest, because what agents query every day is a
syntax graph that misses real uses.

v4 keeps only the query and refactor tool and rebuilds it on the analyzer's own
machinery:

1. **Nothing generated is committed, and codegraph has no CI step.** No maps,
   no freshness gate, no pre-push regeneration, no baseline file, no PR comment.
2. **Architecture rules leave codegraph.** They become a policy test in
   krdpass's `test/tools/`, the idiom the repo already uses for nine other rules.
   It runs in the test shards on every push to `dev`. Existing debt is an allow
   list with reasons, and an entry that is no longer needed never fails a build.
3. **One engine: a resident, resolved worker.** A per-checkout background
   process holds the Dart analyzer with its on-disk cache and its search index:
   the same machinery the analysis server uses for find-references. Measured on
   krdpass: repeat queries take 20 to 230ms, a fresh answer after a body edit
   takes under 0.5s, and it idles out to free its 1.2 to 1.7GB.
4. **Exact or it says so.** Answers that need the whole workspace (references,
   impact, rename) wait until analysis is complete instead of answering early.
   I caught the language server returning a rename with 9 edits while it was
   still analyzing. The same request returned 15 edits once analysis finished,
   and the first answer gave no sign that it was partial.
5. **Six verbs instead of thirty-five.** `find`, `show`, `refs`, `impact`,
   `rename`, `why`, plus `doctor`. Every line printed is `path:line`.
6. **Rename covers every kind of symbol and checks itself.** It refuses
   `UNSAFE` changes, never stalls on an unsupported kind, and after applying an
   edit it analyzes the affected files and rolls back if new errors appear.

## 1. What I found

### 1.1 Friction reported on 2026-10-19, verified

| Claim | Verified? | Evidence |
|---|---|---|
| The code-graph check was red on `main` for a week because vault commits added cross-feature imports | Yes, and the cause is structural | Red on every `main` push from 2026-10-12 (run 38279083137) to 2026-10-15, and on PR #397 until a baseline commit landed. Lint reports 12 `lib/core/... -> lib/vault/...` imports from vault commits dated 2026-10-11 to 2026-10-13. The real cause: `code-graph.yml` runs only on `pull_request` and pushes to `main`, never on `dev`, and work lands directly on `dev`. `tools/check_code_graph.sh`, the pre-push hook, checks map freshness but **not** lint. No branch is protected, so the check is required nowhere. A violation stays invisible until a release merge, and nobody owns it there. |
| The pre-push hook forces "regenerate maps" commits | Yes, at scale | Since 2026-07-01, 362 of 2,673 commits touch `docs/maps/`, and 149 do nothing else. On 2026-10-12/13 alone there are 16 `chore(maps): refresh code graph` commits. The most-churned files are `INDEX.md` (191 commits), `core.md` (158) and `ATTENTION.md` (153), which change whenever a count changes. |
| `codegraph check` writes a different graph locally than CI's syntax build | Yes | A resolved build on a snapshot of HEAD rewrote 5 committed maps, for example `jwtProvider`'s reader-edge count goes from 37 to 43. |
| The session hook warns that the skills are older than the binary | Yes | This session: "skills are v3.7.1 (binary v3.9.0)". The skew exists only because scaffolding is copied into the host with a version stamp. CI's pinned v3.7.1 and the local v3.9.0 wrote byte-identical maps for today's tree, so the warning was noise. |
| A bot posts a long "codegraph diff" comment on every PR push | Partly | It edits one comment in place (`--edit-last`). On PR #397 that comment is about 60 lines of in-degree lists and includes a vendored package. I found no sign that anyone acted on it. |
| The analysis server and `dart analyze` already answer some questions | Yes, but not through the agent's tools | `dart language-server` supports references, implementation, call hierarchy, type hierarchy and rename. The Dart MCP server's `lsp` tool exposes only `hover`, `signatureHelp` and `resolveWorkspaceSymbol` ([tool list](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)). |

### 1.2 Wrong or costly answers I found

- **Confidently wrong subtypes.** `impls FeatureKey` prints "no subtypes", but
  `enum Gate` and `enum Backend` both implement it. `engine.dart` reads
  supertypes from syntax clauses even in a resolved build. The
  `EnumDeclaration` branch records none, and class `with` clauses are skipped
  too.
- **Incomplete readers on the everyday graph.** The graph agents actually query
  is the syntax build (`resolvedBuild: 0`). Its `readers jwtProvider` lists 33
  lib files. The resolved build and the analyzer's search both list 39. The 6
  files it misses include real reads such as
  `deps.ref.read(jwtProvider.notifier)` in the dev playground modules. The
  skill sells this graph as "resolved".
- **Noise where precision was promised.** `callers byKey` returns 334 sites,
  all of them `find.byKey` in tests. `find gate` ranks every symbol in a file
  by the file's in-degree, printing the same 53 on every one of them. `uses`
  repeats `readers` and appends seven caveat clauses.
- **`affected-tests` is slower, larger and unused.** After a one-line body edit
  to `walletMethodKey` (3 callers) it forced a 53s resolved rebuild and
  selected 544 test files in 66KB of output, about 16k tokens. The edit touched
  the only line of an expression-bodied function, so it fell back to
  file-level selection. The repo's own `tools/test_changed.dart` selected 191
  tests in 6s, and AGENTS.md already points agents there.
- **Rename refusals that are coverage gaps.** Across both session stores,
  about a dozen distinct targets were refused with `no declaration of "X"
  found`. Half were enum constants, fixed in 3.9.0. The rest are instance
  fields (`HouseholdDetailsView.recordLoading`) and static fields
  (`EcHeadlessWalletPayment.sandboxWallets`). Both still refuse in 3.9.0,
  after 37 to 69s of resolving. CLAUDE.md tells agents never to rename by hand
  after a refusal, so these tasks stalled on a missing feature, not on a
  safety risk.
- **Small paper cuts.** `codegraph lint --help` runs lint. `impact gate.dart`
  and `wiring gate.dart` exit 2 because five files contain that substring. The
  SessionStart passport spends about 450 tokens per session on counts.

### 1.3 How agents actually use it

Bash invocations across 163 sessions in both Claude stores for krdpass-app:

| Verb | Calls | | Verb | Calls |
|---|---:|---|---|---:|
| lint | 274 | | callers | 22 |
| find | 217 | | route | 11 |
| skeleton | 149 | | wiring | 10 |
| rename | 106 | | impls | 6 |
| build | 61 | | review | 5 |
| readers | 50 | | affected-tests | 4 |
| uses | 44 | | impact | 1 |
| sym | 37 | | change, path, callchain, health, plan, trace, diff, unused, untested | ~0 |
| brief | 33 | | | |

Over the same sessions agents ran about 6,800 `rg`/`grep` commands. Much of the
`lint` and `build` use was spent fixing the gate, not asking a question. The
"intent verbs" that CLAUDE.md lists first (`change`, `review`, `impact`) were
almost never run.

### 1.4 Speed and memory of today's tool (krdpass, 2,312 lib files, 3,309 analyzed files, 24GB M-series Mac)

| Operation | Time | Peak memory |
|---|---:|---:|
| Syntax build | 1.9s | 140MB |
| Resolved build (first run / repeat) | 68s / 41s | 2.5GB |
| Navigation query on a fresh graph (native) | 0.2-0.4s | small |
| `rename` of a method or function (indexed) | 0.8s | |
| `rename` of a class, or any refusal of an unindexed kind | 24-69s | |
| `flutter analyze`, whole repo | 46s | |

### 1.5 The spikes behind the v4 design

All five ran against an exported snapshot of HEAD in `/tmp/cg-eval`, never the
live checkout. Scripts are in `/tmp/cg-eval/spike` and `/tmp/cg-eval/scripts`.

**A. `dart language-server` as an oracle.** First answer on a never-seen
workspace: 116s. Second start, with its `~/.dartServer` cache warm: 29s.
Resident memory: 3.5GB. After warm-up, references come back in under 0.5s
(`jwtProvider`: 331 sites in 120 files, 39 of them lib), and
`textDocument/implementation` finds both `FeatureKey` enums.

**B. The language server returns incomplete renames while it is still
analyzing.** A `textDocument/rename` of the static field `sandboxWallets`,
issued as soon as the server accepted requests, returned 9 edits in 6 files.
It omitted all 7 references in 5 lib files. The same request 150s later
returned 15 edits in 11 files. Nothing in the first response marked it as
partial. Any tool that renames has to gate on analysis being complete.

**C. In-process analyzer with its search index, run one-shot.** I used
`AnalysisContextCollectionImpl` (analyzer 14.5.0) with `FileByteStore`,
`enableIndex: true` and every analyzed file added. The answers are exact:
315 `jwtProvider` references in 108 files (39 lib, 69 test), subtypes
`[Gate, Backend]`. But a one-shot process is slow even with a warm cache:
18-24s of setup across **30 analysis contexts** (an artifact of how the
spike listed roots; see section 11), then 21-57s for the first
search touching 108 files. One-shot per query is not viable.

**D. The same analyzer kept resident.** A process that stays up and receives
file changes (`changeFile` then `applyPendingFileChanges`):

| | coarse dependencies (default) | `withFineDependencies: true` |
|---|---:|---:|
| Setup with warm byte store | 24s | 18s |
| First broad query (108 files) | 37s | 21s |
| Same query again | 228ms | 78ms |
| Fresh answers after a body edit in `gate.dart` | 0.3s / 1.6s | 0.1s / 0.5s |
| Fresh answers after an API edit (new top-level function) | 3.2s / 15.7s | 0.2s / 0.6s |
| Resident memory | 1.2-1.7GB | 2.8-3.2GB |

The analyzer's `Search` API (`references`, `directSubtypeReferences`,
`unresolvedMemberReferences`, result kinds such as `INVOCATION`, `READ`,
`WRITE`, `REFERENCE_BY_NAMED_ARGUMENT`) is the machinery behind the analysis
server's find-references, and it is reachable from a library. Two caveats.
References to a field do not include named arguments to its `this.x`
constructor parameter, which is a separate element, so rename has to compose
queries the way the server's rename does. And `FileByteStore` silently writes
nothing unless its directory already exists.

**E. Architecture rules.** A 50-line analyzer plugin (`analysis_server_plugin`
0.3.24) with a `cross_feature_import` rule works in `dart analyze` and
`flutter analyze`. It reported 99 core-to-other-unit imports at no measurable
cost (42s with the plugin, 46s without). Plugin diagnostics are suppressed with
a qualified name (`// ignore_for_file: codegraph_rules/cross_feature_import`).
But the first `flutter analyze` runs after adding the plugin reported nothing
from **any** plugin, riverpod_lint included, and still exited normally. And
krdpass's own CI today prints `No issues found!` for `flutter analyze` on
`dev` (run 39230668363 at 07f1333c1), while the same tree locally yields 8
riverpod_lint infos. The plugin config and those files are identical at both
commits. So riverpod_lint very likely does not run in CI at all. I have not
seen the runner's analysis-server log to prove the cause, but the likely
reason is the cold plugin build on a fresh runner. Separately, krdpass already
writes repo rules as tests (`test/tools/payment_sdk_confinement_test.dart` and
eight `*_policy_test.dart` files), and those demonstrably run in CI.

### 1.6 Prior art, and what to borrow

- **SCIP** ([design doc](https://github.com/sourcegraph/scip/blob/main/docs/DESIGN.md)):
  per-document data instead of one global graph, readable string symbol IDs,
  and reverse lookups left to the query engine. Borrow the string IDs for
  `--json` and for messages. A Dart indexer exists
  ([Workiva/scip-dart](https://github.com/Workiva/scip-dart)). I have not
  checked how current or complete it is, and v4 does not need it.
- **Kythe** ([overview](https://kythe.io/docs/kythe-overview.html)): "better to
  emit incomplete data than to emit incorrect data". v4 enforces this with the
  readiness gate and the post-apply analyze check, not with caveat text.
- **Glean** ([intro](https://glean.software/docs/introduction/)): store base
  facts and derive higher-level ones by rule. In v4 provider readers, subtypes
  and callers are views over one source, the analyzer's reference index, so
  they cannot disagree.
- **Aider's repo map** ([docs](https://aider.chat/docs/repomap.html)): a ranked,
  token-budgeted list of the most-referenced definitions (1k tokens by
  default). Borrow it for `show <area>`. Rank symbols by their own reference
  counts.
- **Serena** ([repo](https://github.com/oraios/serena)): symbol-level find,
  references, rename and symbolic edits over language servers, Dart included.
  It shows that a thin agent layer over a real analyzer is enough for the
  generic questions. codegraph's reason to exist is the domain layer (Riverpod,
  GoRouter, areas, notes, published-package gates) plus the readiness and
  verification gates that a raw LSP call lacks (spike B).
- **Tree-sitter MCP graph tools** (for example Codebase Memory MCP): local,
  uncommitted indexes plus blast-radius queries. Their token-saving figures
  come from their own READMEs, which I have not verified. One hooks Grep and
  Glob to inject graph context. I reject that here: it adds tokens to every
  search.

## 2. First principles: what is needed, and when

| Moment | What the agent needs | Cheapest reliable source | v4 |
|---|---|---|---|
| Orient on an area | Main files, providers, entry pages, gotchas, under 1k tokens | Notes plus a ranked summary | `show <area>` |
| Locate | Where X is declared | Declarations from a parse (exact without resolution); `rg` for strings | `find` (works before warm-up) |
| Read a file's shape | Outline with lines | A parse | `show <file>` (works before warm-up) |
| Understand usage | Every use, with line and role | The analyzer's reference index | `refs` |
| Change safely | Dependents, override sets, provider and route consumers | References plus element model | `impact`, `rename` |
| Verify | Which tests to run | `tools/test_changed.dart` today | Out of scope until M6 proves better |
| Keep architecture | New violations caught where CI is watched | A policy test in the repo | Not codegraph |
| Diagnose the tool | Is it warm, is it right | | `doctor` |

## 3. Keep, cut, change

### Keep

| What | Why |
|---|---|
| A native CLI as the interface | 0.2s calls, works for every agent and for humans. MCP tools are deferred in current Claude Code, which weakens v3's schema-cost objection, but the CLI still reaches Codex, Cursor and terminals. A thin MCP shim can come later. |
| Rename's staged apply, rollback, cancellation, `publishedPackages` refusal, the enum-name-is-data warning | The one capability with a measured benefit: campaign v2 had 0 unsafe treatment attempts against 3 in the baseline arm. |
| The Riverpod domain: `@riverpod` identity, generated provider names, watch/read/listen/invalidate/refresh roles | No generic tool has it. v4 derives it from exact references. |
| Typed GoRouter route topology (the `route` card) | Same reason. It moves into `show <RouteData>`. |
| `docs/maps/notes/` content and path | 1,120 lines of human knowledge, linked from about 20 docs. Moving it would break those links for nothing. |
| The v3 test cases that still apply, especially refusal cases | Twenty-eight releases of edge cases should not be relearned. |
| The never-guess doctrine | Enforced by the readiness gate, oracle tests and post-apply analysis. |

### Cut

| What | Why |
|---|---|
| Committed `docs/maps/*.md`, `INDEX.md`, `ATTENTION.md`, `README.md` | 149 commits of pure churn plus merge conflicts, for files agents rarely open. `show` computes the content fresh. |
| `codegraph build`, `check`, the map writer | Nothing is left to build or gate. |
| `tools/check_code_graph.sh` pre-push hook | Same. |
| `codegraph lint`, `lint-baseline.json`, `codegraph.json` rules | Rules move to a krdpass policy test (section 8). |
| `code-graph.yml` and the PR diff bot | No codegraph step in CI at all. |
| The syntax graph as an answer source for usage questions | It is what produced the incomplete readers. A parse survives only for `find` and `show <file>`, where declarations are exact without resolution. |
| The v3 daemon | Replaced by the resolved worker. |
| SessionStart passport and rebuild | About 450 tokens per session for counts. |
| `init`, `upgrade`, version stamps, skew detection | One consumer. Its scaffolding is hand-owned and version-free. |
| `brief`, `uses`, `readers`, `provider`, `callers`, `refs`, `impls`, `sym`, `skeleton`, `wiring`, `route`, `path` | Merged into `show`, `refs` and `why`. |
| `change`, `review`, `diff`, `impact` (v3) | Merged into the new `impact`. |
| `affected-tests` | Slower and larger than the repo's tool, and unused. Re-entry only through M6. |
| `callchain`, `health`, `attention`, `unused`, `untested`, `plan`, `blueprint`, `trace`, `passport` | Close to zero use. Most are name-matched approximations. `refs` showing 0 already answers "is this dead". |
| `cost: ~N tok` and confidence footers, multi-clause caveats | An exact answer needs no caveat. A partial one gets a single closing line. |
| `refactor_index.json`, `code_graph.json` | The analyzer's index and byte store replace them. |
| `LIMITATIONS.md` in the host | Engine gaps live in the engine repo's issues. |

### Change

| What | From | To | Why |
|---|---|---|---|
| Engine | One-shot syntax or resolved build into JSON | A resident resolved worker per checkout, on the analyzer's search index, with idle exit | Spikes C and D: exact answers in milliseconds once warm, sub-second after edits. |
| Supertypes | Parsed clause text | Element model (`allSupertypes`, mixins, enums, extension types) via `Search` | Fixes the `impls FeatureKey` class of wrong answers. |
| Provider readers | Name-matched file edges | `Search.references(provider element)`, each site classified by its enclosing `ref.watch/read/listen/invalidate/refresh` call, line-level | Catches wrapper-held refs, and readers and refs come from one source. |
| Scope | `lib/` and `packages/*/lib`, plus a test scan on demand | Exactly what `flutter analyze` analyzes: the repo root with its `analysis_options.yaml` excludes, so `test/`, `integration_test/`, `tool/` and analyzed packages are included | Spike C missed a `tool/` reference when scope was hand-listed. |
| Rename coverage | Methods, functions, classes, enums, mixins, top-level variables, enum constants | Every element kind, composed like the analysis server's rename (section 7) | Closes the field and static-field refusals. |
| Refusals | One `REFUSED:` class | `UNSAFE` vs `UNSUPPORTED` | Agents know when a manual rename is fine. |
| Arguments | Substring match, exit 2 when ambiguous | Exact path, then unique basename, then unique substring. If ambiguous, list the candidates, and answer when exactly one candidate is under `lib/` | `impact gate.dart` just works. |

## 4. Target architecture

```
  agent / human
      |  codegraph <verb>           native AOT client, one short process per call
      v
  client ----- loopback socket ----> worker (one per checkout, started on demand)
      |                                 |  AnalysisContextCollection over repo root
      |  cold path, no worker needed:   |    FileByteStore ~/.cache/codegraph/byte-store
      |  find, show <file>              |    enableIndex: true
      |  (parse only, about 2s)         |  analyzer Search: refs, subtypes, dynamic uses
      |                                 |  domain layer: providers, routes, areas, notes
      |                                 |  rename composer + verifier
      |                                 |  file sync: watcher + stat walk per request
      |                                 |  idle exit after 20 min
```

### 4.1 The worker

- **Started** by the first query that needs it, or in the background by the
  SessionStart hook. The hook prints nothing and costs no tokens. There is one
  worker per checkout, under an exclusive lock in `.dart_tool/codegraph/`. The
  v3 daemon's reservation and loopback code is reusable.
- **Warm-up**: build the collection, add every analyzed file, then index all
  files in the background. Measured: about 1 minute with a warm byte store,
  about 3 to 4 minutes on a first-ever run.
- **Sync before every answer.** A stat walk of the analyzed roots (3,309
  files) calls `changeFile` on anything whose mtime or size moved, then
  `applyPendingFileChanges`. A file watcher triggers the same work eagerly, but
  the stat walk is what correctness relies on, because watchers drop events.
- **Readiness.** Each answer that depends on the whole workspace (`refs`,
  `impact`, `rename`, `show` sections with counts) waits until analysis is
  complete. It prints one stderr progress line (`warming: 1840/3309 files`),
  and `--no-wait` turns that into an immediate partial answer marked
  `partial: workspace still analyzing`.
- **Memory policy.** Coarse dependencies by default (1.2 to 1.7GB resident).
  `CODEGRAPH_FINE_DEPS=1` opts into fine dependencies (about 3GB) for faster
  updates after API edits. The worker exits after 20 minutes idle. A
  machine-wide registry in `~/.cache/codegraph/workers/` caps concurrent
  workers at 2 by default and stops the least recently used idle one first, so
  parallel worktrees cannot pile up 2GB processes.
- **Version coupling.** The worker bundles a pinned analyzer, and
  `analysis_server_plugin`'s exact pin for the current stable SDK is the guide.
  All `package:analyzer/src/` use lives in one adapter file, so an analyzer
  bump touches one place. `doctor` compares the bundled analyzer's language
  version with the project SDK's and says which side to update.

### 4.2 Why not the alternatives

- **One-shot resolution per query.** Measured at 60 to 80s per broad query even
  with a warm cache (spike C).
- **A precomputed JSON index refreshed by builds** (v3's `refactor_index.json`):
  exact only right after a 41s build, and stale after every edit until the next
  one. The resident worker is exact continuously.
- **Driving `dart language-server` as the engine.** It needs 3.5GB resident
  against 1.2 to 1.7GB. It answers early and incompletely while analyzing
  (spike B). It has no API for dynamic member uses (rename's `UNSAFE` gate). And
  domain facts would have to be rebuilt from syntax. Its strengths, a
  maintained rename engine and automatic SDK parity, are real. So it stays as
  the differential oracle (section 9), and it is the fallback if analyzer
  internals churn too much to maintain.
- **Sharing the IDE's analysis server.** It would avoid a second process, but
  I found no supported way for another process to query it. The Dart Tooling
  Daemon might expose one in future. I have not checked current DTD services.

### 4.3 Data held by the worker

Nothing of its own is persisted except the analyzer's byte store. In memory:

- the analyzer's per-unit index and element model;
- domain tables rebuilt per changed library: provider declarations (top-level
  variables whose static type is a Riverpod provider, plus `@riverpod`
  functions and classes mapped to their generated names), typed route classes
  and their placements, and the area of each file;
- symbol IDs as readable strings, used in `--json` and messages, SCIP-style:
  `package:krdpass/core/provider/gate.dart#Gate.byKey`.

## 5. Command surface

### 5.1 Verbs

```
codegraph find <query>              declarations by name (works cold)
codegraph show <thing>              one card: file (works cold), symbol,
                                    provider, RouteData, or area
codegraph refs <symbol> [--all]     every use, path:line, grouped by role
codegraph impact <symbol|file>      what changes or breaks if this changes
codegraph impact --diff [--base R]  the same, seeded from the working tree or branch
codegraph rename <symbol> <new> [--apply]
codegraph why <fileA> <fileB>       shortest dependency path, edge kind per hop
codegraph doctor [--stop|--restart] worker state, SDK and analyzer versions, cache
```

Shared flags: `--json`, `--limit N` (default 40 result lines, ending with
`12 more, rerun with --all`), `--no-wait`.

`<symbol>` accepts `Name`, `Owner.member`, `path.dart:name` and
`path.dart:line`. The last one lets an agent that is reading a file ask about
whatever is declared on that line.

### 5.2 What each verb prints

- **find**: exact name matches, then prefix, then substring. Within a tier,
  rank by the symbol's own reference count when the worker is warm, and by
  name length otherwise. One line per hit: `kind name  path:line  (N refs)`.
- **show file**: today's `skeleton`, then imports in and out grouped by area,
  then the providers it declares and reads.
- **show symbol**: signature, first doc line, members with lines, supertypes,
  transitive subtypes (test fakes marked), override chain, reference counts by
  role.
- **show provider**: declaration, kind, family/autoDispose, readers by role
  with counts and the first N `path:line`, and override sites (`overrideWith`
  and friends).
- **show RouteData**: today's `route` card.
- **show area** (`lib/features/payment`, or just `payment`): an Aider-style
  ranked digest within about 800 tokens. Entry pages, providers by reader
  count, most-referenced symbols, providers consumed from other areas, then
  the first 40 lines of `docs/maps/notes/<area>.md`.
- **refs**: sections by role (`ref.watch`, `ref.read`, `ref.listen`, `call`,
  `read`, `write`, `type`, `implement`, `extend`, `mixin`, `override`,
  `named-arg`), lib before test. Each row is `path:line  trimmed source line`.
  This replaces `uses`, `readers`, `callers`, `refs` and `impls`.
- **impact**: for a symbol, its references, then dependents to depth 2 through
  calls, provider reads, subtypes and route placements. Every hop is labeled.
  Published-package crossings and test files are flagged. With `--diff`, each
  hunk maps to the declarations it touches. A body-only change seeds that
  symbol. A signature, directive or top-level variable change seeds the
  declaration's whole reference set. A new file seeds nothing but is listed.
  The output ends with the test files reached.
- **rename**: section 7.
- **why**: kept because `tools/test_changed.dart:380` tells users to run
  `codegraph path <file> <test>`. It prints the path with edge kinds.

### 5.3 Output rules

- Every result line carries `path:line`.
- An answer is exact, or it ends with one `partial: <reason>` line. There are
  no standing caveats and no cost footer.
- An empty answer says why: `0 references (workspace analyzed, 3309 files)`,
  or `no symbol named X; closest: Y, Z`.
- `--json` mirrors the text sections. Cuts are explicit (`"truncated": 12`).
- Exit codes: 0 answered, 2 ambiguous (candidates printed), 3 refused, 64
  usage, 66 cannot analyze (no `package_config.json`, so run `flutter pub
  get`). Every verb answers `--help` without running.

## 6. Freshness without committed files

- The only state is the analyzer byte store, a content-addressed cache. It is
  safe for concurrent processes (temp file then rename). Corrected in 4.0.0:
  it must NOT be shared across checkouts. Some entries carry paths, and a
  cache filled by a checkout at another path silently dropped every `lib/`
  reference in testing. There is one store per checkout, keyed by the real
  path of its root.
- Every answer runs after a sync (section 4.1). There is no "stale graph"
  state for anyone to commit or check.
- If `package_config.json` is missing or older than `pubspec.lock`, every
  resolved verb exits 66 with the fix. `find` and `show <file>` still answer.
- A branch switch changes thousands of files. The worker re-analyzes them, and
  the readiness gate holds whole-workspace answers until it is done.

## 7. Rename

- **Edit-set composition**, modeled on the analysis server's
  `RenameClassMemberRefactoring` and friends:
  - fields: the field, its getter and setter, `this.x` and `super.x`
    parameters, and their named arguments at call sites;
  - methods: the whole override set up and down the hierarchy;
  - parameters: named arguments at every call site and in overrides;
  - classes: constructors, type uses, tear-offs, and generated
    `_$ClassName` references;
  - files: import, export and part URIs.
- **Readiness gate**: a rename computes only after the workspace is fully
  analyzed (spike B).
- **`UNSAFE` refusals**, each with a fixture test:
  - `unresolvedMemberReferences(name)` finds dynamic or unresolved uses of the
    name;
  - the target is a framework override (`build`, `createState`, ...);
  - the target is public API of a `publishedPackages` package;
  - the target is declared in excluded or vendored code;
  - generated files would need regeneration (`build_runner`), so the dry run
    names the generator;
  - the new name collides in a scope.
- **`UNSUPPORTED`** is reserved for kinds not handled yet. The message says a
  manual rename is acceptable, followed by `flutter analyze`.
- **Apply and verify.** Stage, apply, then let the worker re-analyze the
  changed files and their dependents. If any of them has an error that was
  not there before, roll back and print the errors. This catches a missed
  static reference by construction. Dynamic uses are covered by the
  `UNSAFE` gate.
- **Warnings** stay on the dry run: the enum name is used as data,
  `@JsonKey` and serialization names, string literals that spell the old name.

## 8. Architecture rules: a policy test in krdpass, not a codegraph feature

The rules belong to the repository, and the repository already has the idiom.
Add `test/tools/architecture_policy_test.dart` to krdpass:

- It parses import directives with `parseString` (no resolution, milliseconds)
  across `lib/` and `packages/*/lib`, and checks:
  - cross-feature imports (the current unit model and allow pairs);
  - banned provider kinds in runtime code (`StateProvider`,
    `StateNotifierProvider`, `ChangeNotifierProvider`);
  - package confinement ("only these files may import package X"), so
    `payment_sdk_confinement_test.dart` folds into it.
- The rules are a Dart constant at the top of the test. There is no JSON
  config.
- Existing debt is an allow list in the same file: one line per
  `from -> to` with a short reason. It is generated once from today's
  `lint-baseline.json` plus the 12 vault imports, or the vault imports get
  fixed first (Arin's call).
- A new violation fails with the exact line to add, or the fix. An allow entry
  that no longer matches only prints a note. Nobody ever has to rewrite the
  list after a cleanup.
- It runs in the CI test shards, which run on every PR and every push to `dev`
  and `main`, and which the team already keeps green.
- `tools/test_changed.dart` gains one rule: always include
  `test/tools/*_policy_test.dart`. They are cheap, and no import path reaches
  them.

Why not the analyzer plugin first? Spike E shows that plugins can be silently
inactive: in the first runs after setup, and very likely in krdpass CI today,
where riverpod_lint appears not to run. Inline IDE squiggles would be nice, but
not at the price of a gate that can switch itself off. If they are wanted
later, add the plugin for IDE feedback only, and keep the test as the gate.

The CI finding is worth fixing independently of codegraph: krdpass's
riverpod_lint rules are very likely not enforced. A cheap canary is a test
file with one known riverpod_lint violation, plus a CI step asserting that
`dart analyze` on it reports that rule.

## 9. Staying correct

The committed maps proved determinism, not correctness. `impls FeatureKey`
was deterministically wrong in every committed build. v4 tests against
independent oracles instead:

1. **Fixture oracle (engine CI).** For every declaration in the fixture
   project, compare `refs` and the subtypes in `show` with a brute-force walk
   of the resolved units that records element identity at every identifier.
   That walk is a separate, deliberately simple code path. Any difference fails
   the build.
2. **Language-server differential (local, before each release).**
   `tool/lsp_diff.dart`, grown from this plan's probe, starts
   `dart language-server` on a krdpass snapshot and waits until analysis is
   complete. It samples 500 symbols, compares references, implementations and
   rename edit sets, and turns every mismatch into a fixture case.
3. **krdpass scenario suite.** About 20 real questions with hand-checked
   answers, run against a pinned krdpass commit exported to a temp directory.
   Examples:
   - `refs jwtProvider` includes the dev playground modules;
   - `show FeatureKey` lists `Gate` and `Backend`;
   - `rename HouseholdDetailsView.recordLoading` edits exactly lines 87, 128
     and 352 of `household_details_view.dart`, and not the unrelated
     `recordLoading:` named arguments elsewhere;
   - `rename EcHeadlessWalletPayment.sandboxWallets` edits 15 sites in 11
     files, including `tool/`;
   - `impact --diff` on a body-only edit stays at symbol level.
4. **Rename post-apply analysis** (section 7) as the last line of defense,
   in production.
5. **Refusal fixtures**: every `UNSAFE` reason has one fixture that triggers it
   and one that narrowly does not. Ported from v3 where they apply.

## 10. How agents and humans meet it

- **CLAUDE.md, AGENTS.md, `.cursor/rules/codegraph.mdc`**: the codegraph
  block shrinks to about 8 lines:
  - the verbs;
  - "symbols go to codegraph, exact strings go to rg";
  - the refusal contract: `UNSAFE` means stop and report, `UNSUPPORTED` means
    rename by hand, then run analyze.

  The "navigate instead of grepping" absolute goes: grep is right for strings,
  and the rule only made agents feel they were doing it wrong.
- **Skill**: one `code-map` skill of at most 60 lines, owned in krdpass, with
  no version stamp. One example per verb, plus the known limits. `--help`
  carries the details.
- **Hooks**: SessionStart runs `codegraph doctor --warm &`, which starts the
  worker silently. No PreToolUse or PostToolUse hooks.
- **CI and PRs**: nothing from codegraph. Rules fail the test shards. A
  reviewer who wants a blast radius runs `codegraph impact --diff --base dev`.
- **Pre-push**: nothing from codegraph.
- **Humans**: a short README section with the same verbs. Area overviews for
  browsing on GitHub are the notes files, which are written by people and do
  not churn.

## 11. Migration path for krdpass-app

Each step is a commit by path on `dev`, at a quiet moment, announced to anyone
else editing the checkout. Nothing is kept for compatibility.

**Step A, stop the bleeding (today's binary, about half a day).** The order
matters so that rule enforcement never lapses.

1. Add `test/tools/architecture_policy_test.dart` with the allow list
   generated from `docs/maps/lint-baseline.json` and the current lint output.
   Decide the 12 vault imports first: fix or allow. Fold in
   `payment_sdk_confinement_test.dart`.
2. In `tools/test_changed.dart`, always include `test/tools/*_policy_test.dart`.
3. Delete `.github/workflows/code-graph.yml` and `tools/check_code_graph.sh`.
   Every machine runs
   `git config --unset hook.codegraph-fresh.event` and
   `git config --unset hook.codegraph-fresh.command`.
4. `git rm` every generated `docs/maps/*.md` (keep `notes/`), `INDEX.md`,
   `ATTENTION.md`, `README.md`, `lint-baseline.json`, and `LIMITATIONS.md`
   after copying its open entries into engine issues. Add `docs/maps/*.md` to
   `.gitignore` so today's binary can keep writing locally without churn.
5. In `.claude/hooks/code-graph-refresh.sh`, drop the passport and the build;
   keep only `codegraph daemon &`.
6. Optional and independent: add the riverpod_lint CI canary (section 8).

Exit: no `docs/maps` commits and no codegraph CI runs for two weeks. A
deliberately added `lib/core -> lib/vault` import on a scratch branch fails
the policy test locally and in CI.

**Step B, v4 (after M3).**

1. Install v4 and run `codegraph doctor`.
2. Rewrite the agent pointers listed in section 10, plus the codegraph lines in
   standards 07 and 16, in the `feature`, `testing` and `release` skills, in
   `tools/scaffold_feature.dart:204` ("Regenerate the code graph" goes), and in
   `tools/test_changed.dart:380` (`codegraph why`). Historical audits and plans
   keep their old mentions.
3. Remove the `code_graph.json` and `refactor_index.json` lines from
   `.gitignore`, and delete `codegraph.json`.
4. The SessionStart hook becomes the one-line warm-up.

**Pub workspace: not needed.** Corrected in 4.0.0: the 30 contexts in spike C
came from listing each package's `lib/` as a separate root. With the repository
root as the single included path, krdpass is one analysis context of 3,380
files.

## 12. Engine repository cleanup

- Move `plans/`, `codegraph-review.md`, `ripwire-review.md` and the v3
  benchmark results to `archive/v3/`, and start `CHANGELOG.md` fresh at 4.0.0
  with a pointer to the archive.
- Delete the usefulness and perf benchmarks that measure map queries. Keep the
  agent-impact harness, retargeted at krdpass-shaped tasks and measuring wrong
  answers acted on, refusal safety and tokens per solved task.
- The README describes the verbs, the worker, memory use and how to stop it.

## 13. Milestones

| # | Milestone | Scope | Exit criterion |
|---|---|---|---|
| M0 | Stop the bleeding | Migration step A. No engine change. | Two weeks with no map commits and no codegraph CI. The seeded violation fails the policy test. Agents still answer navigation questions with v3. |
| M1 | Worker core | Collection over the repo root, `FileByteStore`, index, sync protocol, readiness, idle exit, worker cap, `doctor`. All analyzer `src/` use behind one adapter. | On a krdpass snapshot: warm restart to ready at most 90s, repeat query at most 300ms, body-edit-to-fresh-answer at most 2s with coarse deps, idle worker exits on time, a third worker evicts the oldest idle one. |
| M2 | Read verbs | `find`, `show` (all forms), `refs`, `why` on the worker; parse-only cold paths. | The fixture oracle passes. The LSP differential on 500 sampled symbols shows no missing reference or subtype. The scenario suite's read questions pass. Median answer at most 400 tokens. |
| M3 | Rename v4 | Composition for every kind, readiness gate, `UNSAFE`/`UNSUPPORTED`, post-apply analysis with rollback, ported refusal fixtures. | Every historically refused target (`recordLoading`, `sandboxWallets`, the static fields and enum constants from the session logs), re-created on a snapshot, applies with `flutter analyze` clean and matches the LSP edit set taken after full analysis, or refuses `UNSAFE` with a named reason. A deliberately missed reference in a test build triggers the rollback. |
| M4 | Delete v3 | Remove the syntax graph, maps writer, build, check, lint, daemon, init, upgrade and the cut verbs. Engine repo cleanup (section 12). | The v3 verbs answer `unknown verb` with the v4 replacement named. Engine `lib/` is well under half of today's 14k lines, as a sanity check rather than a goal. |
| M5 | Agent layer and krdpass migration | Migration step B, new skill, short CLAUDE block, warm-up hook. | CLAUDE block at most 8 lines, skill at most 60, no version stamps anywhere in krdpass. After two weeks of sessions: no new engine issue caused by a wrong answer, and `refs`/`show`/`find` used at least as often as `find`/`skeleton`/`readers` were. |
| M6 | `impact --diff` tests (optional) | Symbol-seeded test lists; optional input to `tools/test_changed.dart`. | On 10 historical commits with mutated bodies, every failing test is in the list, and the list is no larger than `test_changed.dart`'s. If it does not beat the repo tool, drop it. |

## 14. Risks and open questions

1. **Warm-up time.** Ready-to-answer after a restart is about a minute with a
   warm byte store, and 3 to 4 minutes on a first-ever run. The SessionStart
   warm-up hides most of it. `find` and `show <file>` never wait. If agents
   still hit waits often, persist the worker's reference index on idle and
   answer from it for unchanged files while re-analysis runs. That costs more
   machinery, so only build it if session logs show waits.
2. **Memory.** 1.2 to 1.7GB per warm worker, peaking at 2.7GB during warm-up.
   With the IDE's server (3.5GB) and a Flutter run on a 24GB machine this is
   fine for one checkout. The worker cap and idle exit handle parallel
   worktrees. Fine dependencies are opt-in until their memory is acceptable.
3. **Analyzer internals.** `AnalysisContextCollectionImpl`, `FileByteStore`,
   `withFineDependencies` and `Search` live under `package:analyzer/src/`.
   Pinning plus one adapter file contains the churn. If an upgrade ever costs
   more than a day, switch the engine to the language-server client of
   section 4.2.
4. **Analysis contexts.** Corrected in 4.0.0: with the repository root as
   the included path, krdpass is a single context, and setup is about 4s with
   a warm cache. Results are still merged across contexts for repositories
   that have several.
5. **Policy test versus plugin.** The test gives no IDE squiggles. I judge
   that acceptable, because the gate's job is to fail where people look, and
   the test does. Revisit if the plugin's CI behavior is proven reliable with a
   canary.
6. **The riverpod_lint CI finding** rests on comparing outputs, not on the
   runner's server log. Confirm it with the canary before acting on it.
7. **Does `impact` earn its place?** v3's impact family went unused. v4's is
   symbol-precise and line-level, which may change that, or may not. If
   session logs after M5 show near-zero use, cut it.
8. **Upstream.** If the Dart MCP server gains references, implementation and
   rename, the generic half of `refs` and `rename` duplicates it, but the
   readiness and verification gates and the domain layer do not. An issue on
   `dart-lang/ai` costs little. I have not checked whether one exists.
9. **Not verified here:**
   - how complete and current scip-dart is;
   - whether DTD can expose the IDE's analysis server to other processes;
   - pub-workspace setup time;
   - fine-dependency stability on large edits such as a branch switch;
   - other graph tools' token-saving claims.
