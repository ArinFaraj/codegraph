# Usefulness benchmark

A deterministic regression gate on the navigation tasks an agent runs every
session. It answers two questions per scenario:

1. **Is codegraph still correct?** recall/precision/F1 against **frozen,
   hand-verified ground truth** (not the graph's own output).
2. **Is codegraph worth it over grep?** same truth, same scenarios, so the
   tool-call and output-size gap is apples-to-apples.

## Why the ground truth is frozen, not graph-derived

The old version derived truth from the built graph and then scored codegraph
against it. That is circular: if an engine regression dropped a real reader, the
truth dropped it too, so recall stayed 1.0 and the regression was **invisible**.

Truth now lives as hand-verified literals in [scenarios.dart](scenarios.dart),
independent of both codegraph and grep. A regression that makes `readers
homeProvider` miss a file now turns recall red instead of silently agreeing with
itself. When you deliberately change [test/fixture.dart](../../test/fixture.dart),
update the matching `truth` set in the same commit and say why.

## Quick start

```bash
dart run benchmarks/usefulness/run.dart            # table
dart run benchmarks/usefulness/run.dart --json     # full report + results/latest.json
```

Requires **ripgrep** (`rg`) on PATH for the grep arm.

## What it measures

| Metric | Meaning |
|--------|---------|
| **recall** | Fraction of frozen truth found — drops on a real miss |
| **precision** | Fraction of returned items that are correct — drops on a false edge |
| **F1** | Harmonic mean |
| **toolCalls** | 1 codegraph verb vs the N rg passes a scripted grep needs |
| **outputLines** | Proxy for context tokens spent |

Grep tool-call counts assume the agent reads a matched file to disambiguate
(what a real agent does), not a naive single `rg`. Recipes: [grep_baselines.yaml](grep_baselines.yaml).

## Scenarios

| ID | Question | What it guards |
|----|----------|----------------|
| `locate-symbol` | Where is `HomePage`? | baseline locate |
| `locate-member` | Where is `render()`? | member locate |
| `locate-member-cap` | Where is `m13()` past the member cap? | the 12-member render cap must not hide member 13 |
| `provider-readers` | Who reads `homeProvider`? | reader recall |
| `provider-readers-precision` | Readers of `counterProvider`, **excluding** a non-ref `_Bag.listen` and a bare-token mention | **false-positive guard** — a wrong reader edge is the blocker case |
| `call-sites` | Who **calls** `pingTarget`? | AST call sites, not tear-offs |
| `subtype-tree` | Transitive subtypes of `Shape` | hierarchy closure |
| `cross-package-importers` | Who imports `FancyButton`? | lib↔packages boundary |
| `impact-one-hop` | 1-hop dependents of `home_page.dart` | reverse-import impact |
| `duplicate-provider-readers` | Readers of ambiguous `dupProvider` | per-declaration narrowing |
| `untested-providers` | Providers with zero test refs | coverage, testRef closure doctrine |
| `ambiguous-class-refusal` | `DupBase` declared twice — must refuse | the trust doctrine: refuse, never first-wins |

## What this benchmark does NOT tell you

- **Whether a real agent ends up with a better answer.** This scores the tool's
  raw retrieval, not the agent's final reasoning. For that, use the agent A/B in
  [../README.md](../README.md).
- **Correctness on a real repo.** The fixture is synthetic and built to exercise
  known shapes. It is a regression gate, not proof the tool is right on your app.
- **That codegraph "beats grep" in general.** It shows codegraph needs fewer
  tool calls for equal-or-better retrieval on these specific shapes. Grep ties on
  simple unique-name locates; neither wins on behavioral/runtime questions.

Read per-scenario recall/precision, not the average — the average hides which
capability regressed.
