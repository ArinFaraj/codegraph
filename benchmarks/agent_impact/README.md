# Agent-impact benchmark (Stage A)

The north-star measurement (ROADMAP doctrine 8, plans/BRD-actuator.md section
3, plans/3.2 Stage A): does codegraph improve a real agent's end-to-end work,
with-vs-without, on tasks where correctness is checkable? Everything else in
benchmarks/ measures retrieval or speed; this measures impact.

## Design

Two otherwise identical agent arms run the same frozen prompts in disposable,
production-shaped workspaces ([workspace.dart](workspace.dart) - a small
Flutter-like app with local path deps, resolvable offline):

- **baseline** - the workspace plus a PATH shim making `codegraph` exit 127
  (keeps the arm honest on machines with a global install).
- **codegraph** - the same workspace after `codegraph init` + `codegraph build`
  (compiled from THIS checkout, so results track current code), with the
  CLAUDE.md block mirrored to AGENTS.md for non-Claude agents.

Prompts are identical across arms; the environment is the only treatment.
Arm order alternates per run to cancel ordering effects.

## Tasks ([tasks.dart](tasks.dart))

Four edit tasks (rename a standalone function; a private helper beside an
unrelated same-name; a Riverpod provider/Notifier pair; an interface method
across impls and test fakes) and four must-refuse tasks (ambiguous same-name
collision; framework override contract; public package boundary with unseen
external consumers; a signature change requiring a type that does not exist).

## Scoring (code-computed, never an LLM judge)

An attempt passes only if ALL hold:

- edit tasks: every frozen oracle regex satisfied, git diff confined to the
  task's allowed files, no untracked leftovers;
- refusal tasks: the working tree is completely unchanged;
- `dart analyze` and `dart run test/all_tests.dart` are green;
- no timeout.

Wall time is always recorded; agent steps/tokens are parsed from the agent
CLI's session export when available (devin). Aggregates are computed in code.

## Honesty guards (CI: test/agent_impact_test.dart)

- the untouched workspace FAILS every edit oracle (no vacuous oracles);
- a scripted reference edit PASSES every edit oracle and stays green (every
  task is completable);
- every refusal premise is verified against the fixture (exactly two unrelated
  `helper()`s, the framework `build` contract, the published-package claim,
  the absence of a `Money` type).

## Run it

```bash
# both arms, all 8 tasks, 3 runs each, devin swe-1.7:
dart run benchmarks/agent_impact/runner.dart --agent devin --runs 3

# quick single-task check:
dart run benchmarks/agent_impact/runner.dart --agent claude \
  --tasks rename-standalone-fn --runs 1

# any agent CLI:
dart run benchmarks/agent_impact/runner.dart \
  --agent-cmd 'mytool --yolo -p {prompt}'
```

Results append to `results/*.jsonl` (one record per attempt) plus a printed
per-arm summary. Not a CI gate - agent runs cost time/quota and are
model-dependent; CI gates only the harness self-checks.

## Interpreting (the pre-registered gate from plans/3.2)

Do not expand actuator scope unless the codegraph arm has 100% safety
(refusals + zero unrelated edits) and either improves task success by >= 20
percentage points or cuts time/tool use by >= 30% without reducing success.
Expect run-to-run noise; n=3 per cell is a floor, not a target.

## Known limits

- The workspace is synthetic (production-shaped, not production-scale); a
  companion private-host run covers scale (see benchmarks/README.md honesty
  rules about host scenarios).
- Refusal scoring accepts silent no-ops as refusals; the balancing edit tasks
  punish do-nothing agents.
- Model choice changes absolute numbers; only the with-vs-without DELTA on the
  same model is meaningful.
