# codegraph v5: plan

Status: M1 (`check`) shipped in 4.3.0 and M3 (answers with code) in 4.4.0,
both on 2026-10-20, and M4's translation-key link in 4.5.0 the same day,
ahead of the audit because it was exact and nearly free once `show` answered
with code. M2's audit is due around 2026-11-03; gates, channels and M5 wait
on it. Risk 4 is settled: a `PostToolUse` exit-2 report on a Bash call
reaches the agent under T3 Code (probed 2026-10-20). Measured on a krdpass snapshot through the real CLI and worker:
`check --all` 2.3s, printing exactly what `dart analyze` prints minus the 23
riverpod_lint infos; the hook 50 to 70ms on a shell command that wrote
nothing, 0.4 to 0.6s after a one-file edit, 3.1s after an API break that
produced 221 problems in 960 dependent files.

Based on:

- reading the 4.2.0 engine and running every verb against krdpass-app;
- mining all 168 agent sessions recorded for krdpass-app in both Claude
  stores, plus a hand-labeled sample;
- the last 200 CI runs on `dev`, with their failed-job logs;
- four spikes on an exported snapshot of krdpass HEAD (`7ed1520d8`) in
  `/tmp/cgspike`;
- primary sources for Claude Code hooks and LSP plugins, the Dart MCP server
  and the related dart-lang/ai issues.

The v4 plan (`docs/rewrite-plan.md`) is the baseline. Its decisions to commit
nothing, add no CI step and keep architecture rules in the repo's tests all
stand.

## The short version

v4 made codegraph correct. It is still a tool that waits to be asked, and
agents don't ask:

- In the five krdpass sessions since 4.0.0 shipped (other than the one that
  built it), agents ran zero codegraph 4 queries and about 960 greps.
- CLAUDE.md has told agents for weeks to check edits with the Dart MCP
  server's `analyze_files`. They called it 211 times, and ran `dart analyze`
  or `flutter analyze` through Bash 5,805 times. **Instructions don't change
  what agents reach for. Only a tool that shows up on its own does.**

Meanwhile, the waiting is real and measurable:

- Analyze runs took a median 15s, a 90th percentile of 63s, and **52.7 hours**
  in total. Most of what they found was compile errors and unused imports.
- **Half of all lookups** (50% of 6,954 greps, 54% of 348 codegraph calls)
  were followed within two calls by reading the file they had just found.
- The analyzer that codegraph already keeps warm returns the diagnostics of
  the whole workspace in **0.45s**. After an edit that broke 75 files, it named
  all 75 in **5.2s**. With the analysis options applied, it matches `dart
  analyze` exactly on Dart files (spikes, section 1.5).

v5 is **the warm analyzer for this checkout, shared by every agent working in
it. It speaks first when an edit breaks something, and when asked, it answers
with the code itself, not a pointer to it.**

1. **`check`, delivered by a hook on every tool call that can write a file**
   (Edit, Write, and Bash, which is how most edits here are made). It is silent
   when nothing broke. When something did, it puts the new errors next to the
   tool result that caused them, covering the edited files and every file that
   depends on them. `codegraph check --all` replaces local `dart analyze`
   before a push.
2. **Answers that carry code.** `show` prints the declaration's source,
   `refs` answers every candidate instead of exiting 2, and `find` answers from
   the worker's memory.
3. **Links grep is used for and cannot follow:** translation keys (exact,
   through the generated getters), gates, and platform channel handlers.
4. **Later, and only if 1 and 2 hold up:** a thin LSP front, so Claude Code's
   built-in `LSP` tool works for Dart against the shared worker.
5. **Cut** `why`, `impact <symbol|file>`, and name-based mention counts.

## 1. What I found

### 1.1 How agents work in krdpass-app

All 168 sessions for krdpass-app and its worktrees:

| Activity | Calls |
|---|---:|
| `rg` / `grep` | 36,852 |
| `flutter test` / `tools/test_changed.dart` | 6,880 |
| `dart analyze` / `flutter analyze` (2,912 whole repo, 2,893 by path) | 5,805 |
| `gh run view/watch/list` | 1,031 |
| codegraph, every version | about 2,000 |
| Dart MCP `analyze_files` | 211 |

Local test runs have been banned since 2026-09-30, because parallel
`flutter test -j 16` runs froze the machine. Since then:

| | Before the ban | Since (3 weeks) |
|---|---:|---:|
| analyze runs | 3,810 | 1,990 |
| Median / total analyze wait | 17.9s / 39.1h | 11.8s / 13.6h |
| Dart writes via Edit / Write | 2,713 | 436 |
| Bash commands writing `.dart` files (scripts, `sed -i`, redirects; `dart format` excluded) | not split | about 3,200 |
| Test runs (including `test_changed --list`) | 6,028 | 854 |

**Most edits do not go through Edit or Write.** Since the ban, agents wrote
Dart files with Python heredoc scripts (2,594 commands), `sed -i` or `perl
-pi` (453), and shell redirects (152), against 436 Edit/Write calls. The
script count is a regex estimate. A hook that watches only `Edit|Write`
would miss most changes.

**Concurrency.** On the main checkout, two or more sessions were active in
38% of active minutes, and three or more in 21% (per-minute message
timestamps). One analyzer per session (3.5GB for `dart language-server`)
would often mean 7 to 10GB. One shared worker at about 1.8GB does not.

### 1.2 What the agents were looking for

Regex buckets over all greps (they overlap and are approximate): reading
context with `-A/-B/-C` 17.7%, imports 13.1%, translation YAML 9.2%, docs
7.6%, gates 5.8%, declarations 5.1%, providers 4.9%, native code 3.4%,
generated API clients 2.7%, test overrides 2.5%, routes 1.1%.

A hand-labeled random sample of 70 greps since 2026-09-01 is a better guide:

| Kind | Share |
|---|---:|
| Filtering command output (test logs, analyze output, device logs) | about 27% |
| A Dart symbol question codegraph could answer (declaration, uses, value) | about 27%, a third of them wanting the declaration's body |
| Non-Dart config and docs (pubspec, manifests, workflows, Markdown) | about 16% |
| Translation strings and keys | about 6% |
| Other repositories, mixed | the rest |

**Lookups end in a read.** Of 6,954 greps that printed Dart paths, 50.1%
were followed within two tool calls by `Read`, `sed -n`, `cat` or `head` of
a file they had printed. For 348 codegraph lookups (mostly v3 `find`,
`skeleton`, `readers`), the rate was 54%.

### 1.3 What analyze found, and what CI fails on

Diagnostics printed by the agents' analyze runs: 2,653 errors, 1,260
warnings, 712 infos. The top codes were `unused_import` (910),
`undefined_identifier` (424), `undefined_getter` (405),
`undefined_named_parameter` (205), `missing_required_argument` (196),
`argument_type_not_assignable` (195), `undefined_method` (187) and
`uri_does_not_exist` (147). Runs that showed any riverpod_lint plugin
diagnostic: **29 of about 1,480 (2%)**. A check without analyzer plugins
covers nearly everything agents actually hit.

The last 200 CI runs on `dev` (2026-09-30 to 2026-10-19): 98 succeeded, 57
failed, 45 were cancelled. A run takes a median 9 to 9.5 minutes. Failures
by cause:

| Cause | Runs |
|---|---:|
| Test assertions (alone or with goldens and timeouts) | about 33 |
| Goldens only | 10 |
| Compile errors in test shards | 8 |
| The `analyze` job | 7 |
| Timeouts or unclassified | 4 |

About 15 of the 57 failed runs (26%) were the class `check` catches before a
push. Assertion and golden failures dominate, and codegraph cannot help with
those while local tests stay banned. That belongs to the repo's CI design
(section 7), not to this tool.

### 1.4 What gets in the way in 4.2.0, measured today

| Friction | Observed |
|---|---|
| Silent until asked | An edit that breaks 75 files gets no signal. The agent runs a 12 to 60s analyze, or pushes and waits 9 minutes for CI. |
| Answers point, then the agent reads | `show effectiveFeaturesProvider` prints `final effectiveFeaturesProvider = Provider<FeatureConfig?>((ref) {final published = ref.watch(remoteConfigProvi...`. Half of all lookups are followed by a read. |
| Ambiguity costs a turn | `refs signWithCredentialKey` exits 2. The two candidates are a method and the channel-name field for it, and `rg` would have shown both. |
| `find` is slow and its counts are noise | 0.8s per call (`rg` takes 0.08s), because the CLI parses `outline.json` (15.7MB) each time. `find gate` prints "113 files mention it" on every field named `gate`. |
| First symbol answer after warm-up | `show <provider>` took 7.0s with the worker "ready". Repeats take 0.1 to 0.2s. |
| Standing context cost | About 20 lines in CLAUDE.md and AGENTS.md plus a skill in every session, for a tool that went unused. |

What works and stays: warm-up takes 11 to 12s from a warm byte store (six
starts in the worker log). Repeat `refs` takes 0.1 to 0.2s. Provider roles
are exact. Rename and move verify themselves and roll back. The idle worker's
resident memory drops to about 10MB (macOS pages it out) and comes back on
use, so an idle worker costs little.

### 1.5 Spikes: diagnostics from the resident analyzer

The scripts are in `/tmp/cgspike/runner/bin/`. They build on 4.2.0's own
classes against a snapshot of krdpass HEAD.

**Latency** (`spike.dart`, fresh byte store; the edited file
`feature_gate_provider.dart` has 75 dependents):

| Step | Time |
|---|---:|
| Open, then index every file (empty byte store) | 13.5s + 25.7s |
| Diagnostics for every file, first and repeat | 0.45s / 0.43s |
| Body edit: sync, then every file | 63ms + 0.73s |
| API break (renamed the provider): sync, then every file | 62ms + 5.15s, all 75 broken files found |
| Restore | 0.76s |
| `dart analyze` on the same snapshot | 55s |

**Parity** (`parity.dart`, `opts.dart`):

- `AnalysisDriver.getErrors` returns diagnostics before the analysis options
  are applied. Raw, it reported 30 that `dart analyze` hides:
  - 12 `todo`;
  - 13 `unnecessary_import` in `packages/krdpass_ui`, whose own
    `analysis_options.yaml` sets it to `ignore`;
  - 5 `deprecated_member_use` in `packages/wolt_modal_sheet`.
- The context does resolve options per file. `getAnalysisOptionsForFile` on
  a krdpass_ui file returns its own processors, even though krdpass is a
  single analysis context.
- Applying `ErrorProcessor.getProcessor(options, diagnostic)` (public API,
  `package:analyzer/source/error_processor.dart`) and dropping `TODO`
  diagnostics leaves **0, exactly what `dart analyze` reports for Dart files**.
  That run took 10.6s from a cold process, with peak RSS of 1.0GB.
- `dart analyze` printed two more things the in-process run cannot produce
  yet:
  - 23 riverpod_lint plugin infos;
  - 1 pubspec warning, `asset_does_not_exist` for the gitignored
    `assets/tscfg.txt`. Agents saw this 69 times. It comes from the pubspec
    validator (`package:analyzer/src/pubspec/`), which `check` can run on each
    `pubspec.yaml` from the analysis adapter.

### 1.6 Prior art and primary sources

- **Claude Code hooks** (docs read 2026-10-20):
  - `PostToolUse` input carries `tool_name`, `tool_input` (`file_path` for
    Write/Edit), `tool_response`, `tool_use_id` and `duration_ms`.
  - On exit code 2, Claude sees stderr next to the tool result.
  - `"async": true` delivers output on the next turn. `asyncRewake` wakes
    Claude on exit 2 even when idle.
  - **A `PostToolUse` hook on `Edit|Write` does not fire when Bash rewrites
    a file.** For Bash, `tool_response.bashEditDiff` lists changed files, but
    it is "best effort and in public beta" and only on by default in auto and
    bypass modes. A `FileChanged` event fires on any write, but only for
    files on its watch list, and it can't send output to Claude.
- **Claude Code LSP plugins** (plugins reference, "Code intelligence
  plugins", tools reference):
  - A plugin's `.lsp.json` maps file extensions to a server command.
  - Claude then gets a read-only `LSP` tool, and "after each file edit, it
    automatically reports type errors and warnings".
  - There are 13 official language plugins. Dart is not one of them.
  - Here, the `LSP` tool answered "No LSP server available for file type:
    .dart".
- **Dart MCP server** (dart-lang/ai, release 1.2.1 prepared 2026-10-16):
  - Its `lsp` tool still has only `hover`, `signatureHelp` and
    `resolveWorkspaceSymbol` (read from `mixins/analyzer.dart` on main).
  - It starts its own `dart language-server` per server instance, so every
    session that uses it pays for its own analysis server.
  - Issue #300, "Support refactorings", is **open**. The maintainers agree it
    would be useful, and say the hard part is evaluating that models use such
    tools well. #451, which asked to expose rename and the analyzer index, was
    closed 2026-04-23 as a duplicate of #300.
  - In #300, DanTup explains that a secondary client can send requests to
    the IDE's analysis server over DTD, but edits always go back to the
    primary client (the editor). That answers v4's open question: another
    process can query the IDE's server through DTD, but it can't apply a
    rename without the editor. It is also only there while an IDE runs.
- **Other agents' after-edit diagnostics:** Hermes, Kimchi and pi extensions
  feed language-server diagnostics back after writes. None of these pages
  publishes an evaluation. In the Cursor forum (Aug 2026, role of the replier
  not stated), the answer is that "most LSP servers only publish diagnostics
  for open documents", so files affected indirectly by an edit can be missed.
  It also says Cursor's CLI runs no extension host. Covering the dependents is
  where a whole-workspace `check` differs from editor-style diagnostics.
- **Hooks elsewhere** (third-party write-ups, not checked against vendor
  docs): Cursor has an `afterFileEdit` hook in `.cursor/hooks.json` with a
  `file_path` payload. Codex CLI has `PostToolUse` hooks in `hooks.json`. Both
  read JSON on stdin, so one `check --hook` with a small input adapter could
  serve all three.

## 2. First principles

An agent's loop here: orient, locate, read, edit, verify, push, wait for CI.

| Step | What it costs now | v5 |
|---|---|---|
| Verify after an edit | 12 to 63s per analyze; 13.6h in the three weeks since the test ban | `check` in the hook, about 1s, silent when clean |
| Catch it before CI | About 15 of 57 failed `dev` runs were compile or analyze failures, at 9 minutes each plus the fix | `check --all` before a push, under 1s |
| Read what was located | A second call after half of all lookups | `show` prints source; `refs -C` gives context |
| Follow a string link | Several greps across YAML, Dart, Kotlin and Swift | Domain links in `show` and `refs` |
| Locate a declaration | `rg` takes 0.08s and is fine | `find` at `rg` speed, ranked by real use |
| Rename or move | By hand, or v4 | Keep v4 |

Principles:

1. **Speak first, only when it matters.** Silence on success costs nothing.
2. **Hook every write, whatever made it.** Most edits here come from Bash.
3. **Answer with the code.** A location is half an answer when the next step
   is always to read it.
4. **Never make the agent ask twice.** Answer every candidate when there are
   only a few.
5. **One analyzer per checkout, shared** by sessions, hooks, the CLI and an
   optional LSP front.
6. **Win on meaning, not text.** Leave log filtering and config greps to
   `rg`.
7. **Exact, or say partial. Nothing committed, no CI step.** Kept from v4.

## 3. Design

### 3.1 The worker: unchanged core, plus a diagnostics ledger

The v4 worker stays: one per checkout, the analyzer with its index, a
stat-walk sync before each answer, idle exit, a two-worker cap. Additions:

- **Ledger.** After warm-up, the worker holds every file's diagnostics with
  the stamp they were computed at, refreshed on each sync.
- **Filtering identical to `dart analyze`.** Apply
  `ErrorProcessor.getProcessor` with each file's own options, drop `TODO`, and
  honor ignore comments (the driver already does that). Add the pubspec
  validator for each `pubspec.yaml`. All of this goes in the one adapter file.
- **Attribution by write time.** A `check` request carries a time window,
  for a hook the tool call's start and end from `duration_ms`. The worker
  syncs, takes the files whose modification time falls inside the window,
  recomputes their dependents, and reports only diagnostics that are new
  against the ledger in those files and their dependents. Another agent's
  write in the same few hundred milliseconds would be attributed too. That is
  rare, and its error would be real anyway.

### 3.2 `check`

```
codegraph check [paths...]   new diagnostics these files cause, in them and their dependents
codegraph check              the same for everything changed since the last check
codegraph check --all        every diagnostic in the workspace, the pre-push gate
codegraph check --hook       hook mode: reads the hook JSON on stdin
```

- Output: one line per diagnostic,
  `path:line:col  severity  code  message`, followed by its source line and
  grouped under the written file that caused it. When the answer is clean,
  print nothing and exit 0. With new errors, exit 1. In hook mode, exit 2 with
  the report on stderr.
- `--all` ends with one fixed line: `analyzer plugins (riverpod_lint) are not
  run; CI runs them`.
- The hook in krdpass's `.claude/settings.json`:

  ```json
  {"matcher": "Edit|Write|Bash", "hooks": [{"type": "command",
    "command": "codegraph check --hook", "timeout": 20}]}
  ```

  - **Synchronous on purpose.** The report sits right under the tool result
    that caused it, before the agent's next step.
  - **Cost of a clean call:** about 60ms for the stat walk on Bash commands
    that write nothing, which is most of them. A body edit costs under a
    second. An API break costs about 5s, still less than half the median
    analyze it replaces.
  - **Fallback:** if measured latency hurts, switch to `asyncRewake`.
- **Never block or nag.** If the worker isn't warm, the hook waits at most
  10s and then exits 0 silently. It ignores tool calls that wrote no Dart,
  pubspec or analysis options file.
- **Not covered:** analyzer plugins, and anything only a Flutter or native
  build sees. `--help` says so.

### 3.3 Read verbs: answer with the code

- **`find <name>`**: answers from the worker's in-memory outline when it is
  running (target 0.1s). Otherwise from a compact cold cache in place of the
  15.7MB JSON (target 0.2s). Drop the name-based counts. With a warm worker,
  rank by real reference counts.
- **`show <symbol>`**: the declaration's full source up to 60 lines, then
  members, subtypes, overrides and readers as in v4. `--no-source` gives the
  v4 card.
- **`show <file>`**: the outline and imports as now, with `imported by` in
  full.
- **`refs <symbol>`**: with two to five candidates, answer each one under its
  own heading. Exit 2 only above five. `-C N` prints context lines.
- **`show <dir>`**: counts switch from name mentions to resolved references.

### 3.4 Domain links

| Link | How it is found | v5 |
|---|---|---|
| Translation key (`t.onboarding.restart`) | **Exact.** The resolved use points at a generated getter whose body carries the dotted key (`TranslationOverrides.string(_root.$meta, 'onboarding.restart', {})`). That key gives the YAML node, located with spans from `package:yaml`. | `refs t.onboarding.restart`: the Dart uses, the line in each of `en`, `ar`, `ckb`, `kmr`, and any locale missing the key |
| Gate (`Gate.inAppUpdate`) | Resolved enum value, plus the string key in its constructor (`'payment.method.new_card'`) and `publishedKey` | `show Gate.x`: declaration, readers by role, test overrides, and the key |
| Channel method (`signWithCredentialKey`) | Text, labeled as such: the name inside handler files for the channel's name string (Swift `case "signWithCredentialKey":`, Kotlin `ChannelMethods.signWithCredentialKey ->`) | `show` on a channel-name field or an `invokeMethod('x')` lists the Kotlin and Swift handler lines |

krdpass has 12 Dart files that declare channels. Paths (the i18n YAML
directory, the generated strings file, the native roots) come from an
optional `codegraph.yaml` in the repo, never hard-coded.

### 3.5 Rename and move

Unchanged from 4.2: this is the one capability with a measured benefit. Two
additions:

- After `--apply`, print the `check` result for the edited set. Rollback
  already computes it.
- `@riverpod` and `@freezed` renames, which are `UNSAFE` today, can run the
  generation command named in `codegraph.yaml` and then verify. Without that
  command, they stay `UNSAFE`.

### 3.6 Optional: an LSP front

`codegraph lsp` would be a stdio LSP server with no analyzer of its own. It
forwards definition, references, implementation, symbols, call hierarchy and
hover to the shared worker, and publishes diagnostics from the ledger for
written files and their dependents. A small Claude Code plugin with a
`.lsp.json` (`".dart": "dart"`) registers it.

It gives native symbol navigation with no Bash and no CLAUDE.md lines. But
Claude Code's after-edit diagnostics come from the editing tools, and most
edits here go through Bash (section 1.1). So the hook stays the delivery path
for `check`, and the LSP front is about navigation only. It is built only if
the M3 audit shows codegraph's read verbs being used. If they aren't, a
native tool may be what's missing, and this is the experiment that tests it.

### 3.7 Cut

| What | Why |
|---|---|
| `why <fileA> <fileB>` | 10 calls in the whole history, most of them prompted by a hint in `tools/test_changed.dart`, which already has the import graph and can print the chain itself. |
| `impact <symbol\|file>` | 11 calls in the whole history. `refs` covers it. The v4 plan's risk 7 says to cut it at near-zero use. |
| `impact --diff` | Folds into `check`. Test selection stays with `tools/test_changed.dart`. |
| Name-based mention counts | They rank nothing. |
| JSON outline cache | Replaced by worker memory, with a compact cold cache as the fallback. |

## 4. How krdpass meets it

- **Hooks:** SessionStart keeps `codegraph doctor --warm &`. `PostToolUse`
  on `Edit|Write|Bash` runs `codegraph check --hook` (section 3.2).
- **CLAUDE.md and AGENTS.md:** the codegraph block shrinks to about four
  lines. Errors from your writes arrive on their own; run `codegraph check
  --all` before pushing; `show` and `refs` for symbols; `rename` for renames
  and moves.
  - The AGENTS.md rule "Check an edit with the analysis server" becomes
    `codegraph check`.
  - `test-and-analyze-costs.md` gets the new numbers.
- **Memory `no-local-test-runs`:** the local gates become `codegraph check
  --all`, `tools/check_import_weight.dart` and the policy tests. `dart
  analyze` stays as the fallback without codegraph.
- **Skill `code-map`:** at most 30 lines, mostly domain links and the
  refusal contract.
- **Cursor and Codex:** the same `check --hook` behind their own hook
  formats, after confirming those formats against vendor docs.

## 5. Staying correct

v4's oracles stay: the fixture oracle, `tool/lsp_diff.dart` before each
release, and the rename post-apply check. New:

1. **Parity fixture (engine CI):** nested packages with their own
   `analysis_options.yaml` (`ignore`, raised severity), ignore comments,
   TODOs, and a pubspec with a missing asset. `check --all` must print
   exactly what `dart analyze` prints, minus plugin rules.
2. **Parity on krdpass (before each release):** the same comparison on a
   snapshot, plus one seeded API break. This is spike `parity.dart` promoted
   to a tool.
3. **Attribution fixtures:**
   - A Bash-style write inside the window is reported.
   - A write by "another agent" outside the window is not.
   - An error that already existed is reported to nobody.
4. **Domain link fixtures:** a slang key missing in one locale is flagged; a
   gate override in a test is listed under `override`.
5. **Session audits** (section 6) are the real exit tests.

## 6. Milestones

| # | Milestone | Scope | Exit criterion |
|---|---|---|---|
| M1 | `check` | Ledger, filtering parity, pubspec validation, window attribution, `check`, `--all`, `--hook` | On a krdpass snapshot: `--all` matches `dart analyze` minus plugin rules, with and without a seeded break. A clean Bash call costs at most 100ms in the hook, a body edit at most 1.5s, an API break at most 8s. |
| M2 | Hook in krdpass | The hook; CLAUDE.md, AGENTS.md and memory updates | Two weeks of sessions: Bash `dart/flutter analyze` runs fall by at least 80% against the 1,990 of the three weeks after the test ban, at a similar write volume. `analyze`-job and compile failures on `dev` CI fall from about 15 per 200 runs to at most 3. No report of the hook blocking a session or blaming another agent's error. |
| M3 | Answers with code | `show` source, multi-candidate `refs`, `-C`, `find` from the worker, compact cold cache, real-use ranking; cut `why` and `impact` | `find` at most 0.2s cold, 0.1s warm. Session audit: lookups followed by a read of the hit fall from 50% to at most 30%, and codegraph read verbs run at least 1 per 10 greps (today 0). |
| M4 | Domain links | `codegraph.yaml`; i18n, gate and channel links | Session audit: greps over `lib/core/i18n/yaml` fall by half. |
| M5 (optional) | LSP front | `codegraph lsp`, Claude Code plugin | Built only if M3 misses its usage target. Exit: Dart lookups through the `LSP` tool, one worker for three parallel sessions. |

M1 and M2 come first: they carry the measured hours, and the worker already
has `errors()` and rename's verify step to build on.

## 7. Risks and open questions

1. **Hook overhead on every Bash call.** Agents run thousands of Bash
   commands. The clean path must stay a stat walk with no analyzer work:
   about 60ms measured for the sync. Budget 100ms, and measure it in M1.
2. **Window attribution** misses writes whose modification time is not
   updated (rare), and catches another agent's write inside the same window.
   It is bounded and harmless. `bashEditDiff` can refine it where it is
   enabled.
3. **Worker not warm** at the first write: 12s after a restart, about 40s on
   an empty byte store. The hook gives up silently after 10s.
4. **The T3 Code harness** runs Claude Code, and the SessionStart hook
   already fires there. I have not confirmed that `PostToolUse` with exit 2
   behaves the same there.
5. **Plugin lints** (2% of analyze runs) stay with `dart analyze` and CI.
   Settled 2026-10-20: `flutter analyze` returns before plugins report
   (dart-lang/sdk#63787), so CI never ran riverpod_lint. krdpass CI now runs
   `dart analyze --fatal-infos` plus a canary step (`93129a534`).
6. **CI failures are mostly tests.** About 42 of 57 failed runs were
   assertions, goldens or timeouts, which codegraph cannot prevent while local
   tests are banned. Worth raising separately: run the tests
   `tools/test_changed.dart` selects first in CI, and fail fast.
7. **Behavior is the real risk.** v4 assumed better answers would be used.
   M2 and M3 are judged on session audits, and if M3 misses, stop adding read
   features.

## 8. Not verified here

- That Claude Code shows `PostToolUse` exit-2 stderr for Bash calls exactly
  as it does for Edit. The docs say it does for `PostToolUse` in general.
- The ledger's steady-state memory inside the worker. The cold parity run
  peaked at 1.0GB RSS, and the warm 4.2 worker sits near 1.8GB.
- Cursor's and Codex's hook formats beyond third-party write-ups.
- The pubspec validator's output parity with `dart analyze` across every
  pubspec rule (only `asset_does_not_exist` was observed).
- The CI cause buckets come from regexes over `--log-failed` output, and
  overlapping causes were counted once per run.
- The grep intent buckets in 1.2 are regex heuristics. The 70-grep sample is
  hand-labeled but small.
