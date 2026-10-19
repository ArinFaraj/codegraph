# ripwire, read against codegraph

_Assessed 2026-09-07 against redhat-et/ripwire (Apache-2.0, C++23, v0.3.8,
shallow clone of `main`). Written to record dispositions so nothing here gets
re-proposed later without a new trigger._

## Verdict

**The engine is worthless to us. The measurement doctrine is worth taking, and
one verb is missing.**

ripwire is a tree-sitter-based, name-resolved code map for coding agents:
one static binary, ranked symbols with complexity/churn/blast-radius inline,
a token-budgeted bundle, an optional MCP server. Same problem as codegraph,
opposite engine. Its whole approach - name-based edges over vendored grammars -
is the thing `CHANGELOG` already rejected for correct, specific reasons
(providers fragment into one node per reader, framework navigation needs type
resolution). ripwire's own honesty section concedes the horizon: a name-based
graph cannot see dynamic dispatch, a callback through a table, or a
macro-expanded symbol, and its recommended escalation is `--scip=index.scip`,
which is a compiler index. We start from the compiler index. There is nothing
in its extraction layer to copy.

What is worth copying is how it measures itself, and one verb.

## What it independently confirms (no action)

- **MCP server mode.** ripwire ships one and then argues against registering
  it: "the verb schemas sit in the agent's context every session, so register
  it when you want those verbs, not as a default." That is the CHANGELOG's
  rejection reached independently by a project that built the thing. Keep the
  rejection; this is corroboration, not a new trigger.
- **PageRank and BM25 ranking (currently deferred "pending evidence of
  need").** ripwire measured PageRank at 3.8 percent recall@5 as a co-change
  ranker against 40.3 percent for plain lexical, and reports that fusing the
  two made it worse. That is evidence for keeping them deferred, not against.
- **Determinism and refusal.** Two runs byte-identical, warm output identical
  to cold, a differential argv harness against a reference binary, and
  staleness/ambiguity refusal on its edit verbs. Same doctrine as ours,
  arrived at separately. Nothing to change.

## The thing actually worth taking

Our own north-star data and ripwire's say the same uncomfortable thing, and
ripwire has the methodological answer we do not.

**Ours** (`benchmarks/agent_impact/results/`, 4 edit + 4 refusal tasks x 3
runs x 2 arms):

| | baseline | codegraph |
|---|---|---|
| campaign-v2-v35 edit | 12/12 | 11/12 |
| campaign-v2-v35 refusal | 9/12 | **12/12** |
| campaign-v2-v35 median prompt tokens | 181,543 | 254,043 |
| campaign-v2-v35 median steps | 17.5 | 21.5 |
| campaign-devin-swe17 edit | 12/12 | 12/12 |
| campaign-devin-swe17 refusal | 9/12 | 9/12 |
| campaign-devin-swe17 median prompt tokens | 171,049 | 215,620 |

The v2 verdict commit already says it: "value half of the gate still unmet at
15-file scale (+8.3pp, slower medians), as predicted: value needs production
scale."

**Theirs** (48 runs, `claude -p` Sonnet, scored by the official swebench 5.0.2
harness, pre-registration frozen by sha256 before any run was funded):
resolved 15/24 in **both** arms, and **discordance 0.083** - only 2 of 24
paired instance-seed outcomes differed at all. Their conclusion is the useful
part: a 10-point arm effect is arithmetically impossible under 8.3 percent
discordance, so on that population the outcome metric cannot discriminate
between *any* two context tools, and funding another round of it would buy
nothing. They re-aimed the primary endpoint at output tokens per resolved
task, paired, and retired two circulated overhead figures (+80 percent, +135
percent) on the record as non-comparable because they came from a different
harness with an unisolated baseline.

Three things follow for us.

### 1. Publish paired discordance before reading any arm delta

`benchmarks/README.md` honesty rules 1-6 cover ground truth, failability,
paired arms, code-computed aggregates, xfail and executable oracles. None of
them covers **endpoint power**. Discordance is one number computed from data
we already have, and it says in advance whether the comparison can produce a
signal at all. On the edit tasks our arms differ on 1 of 24 paired outcomes;
that is the +8.3pp footnote expressed as a statistic that stops the argument
instead of inviting another campaign. Add it as honesty rule 7, and compute it
in `analyze.dart`.

This matters for roadmap item 6, which gates P2 expansion on the benchmark
proving the thesis. If the edit-success endpoint is structurally incapable of
proving it, the production-scale arm should not be funded to try.

### 2. Our refusal tasks are the instrument; ripwire never found one

The single most important asymmetry: ripwire looked for a discriminating
endpoint and did not find one. We have one. `refuse-public-boundary` split
0/3 against 3/3, and the v2 campaign is 12/12 against 9/12 overall on
refusals. Safety discriminates where task success does not, on a population
where a strong agent solves nearly everything either way.

The value claim should be restated to match the evidence we actually have:
codegraph buys **safety at a cost premium**, not speed or success rate. That
is a defensible and unusual claim. "Cut agent understanding-time from ~25-35k
tokens per feature to ~9-12k" (0.2.0) is a retrieval-side measurement that the
end-to-end data contradicts at the session level, and it should either be
re-measured end to end or scoped explicitly to per-query cost.

### 3. Re-aim the value endpoint at cost per successful task

Their Stage 2 does exactly this and it is the right move here too: paired cost
per passing task, not success rate. Our medians currently move the wrong way
(steps 17.5 to 21.5, prompt tokens +40 percent in v2), which is a real finding
reported as an aside. Either the production-scale arm shows the cost line
crossing, or the cost premium becomes part of the stated deal.

## Four concrete borrowables, ranked

**1. Answer-level confidence with a margin.** We have edge-level provenance
(`resolved`/`heuristic`/`guessed`) and a per-verb caveat line, which is more
than most tools ship. We do not have one field saying how much to trust *this
ranking*. ripwire emits `confidence="high" margin_pct="20"` derived from the
score gap between rank 1 and rank 2, and emits `low` on a flat ranking so the
agent reads the answer as a starting point rather than an answer. `find`
returns a score suffix and says nothing about separation. This is a small
change in `find`/`brief`, it serves NEVER-GUESS rather than fighting it, and
it is the cheapest item on this list.

**2. Token cost in the envelope.** Doctrine 5 budgets lines; `INDEX.md`
already computes a token column as chars/4. Put `estTokens` on every `--json`
envelope and one line in text output. It is the same arithmetic applied to
verb output, and it is the per-call number recommendation 3 above needs in
order to measure cost per task at all.

**3. A `trace` verb.** ripwire's `--from-trace=FILE` resolves every frame of a
stack trace to definitions in one call; it is their best-measured ratio
(roughly 87x to 209x against grepping frame names then opening files).
Flutter throws stack traces constantly, we have no equivalent verb, and our
resolved element model would make it strictly more precise than their
name-based version - frame to real declaration, with the override chain.
It composes from `sym` and `skeleton` machinery that already exists. This is
the one genuinely missing capability in the comparison.

**4. Churn and amplification inline on `change` / `review` / `health`, verb
output only.** ripwire annotates each ranked symbol with `churn=` (recent git
edits) and `amp=` (how many graph nodes feel a change) so the fragile spots
are visible before anything is touched. We rejected churn in **committed
artifacts** for determinism, and doctrine 2 explicitly allows git and
wall-clock in verb output. `change` already computes the blast radius; adding
churn beside it is inside the existing rule, not a reversal of it.

Lower priority, same family: their quality panel ranks by **how many of six
independent evidence families agree** rather than by one blended score, prints
each family's reason inline, and reports only what a change made worse. They
earned the "agreement means something" claim by measuring the families' max
pairwise correlation at +0.168 over 27,889 functions. If `health` ever grows
past triage lists, that is the shape - and the measured-independence step is
the part most tools skip.

## Do not take

- **Tree-sitter extraction.** Already rejected, and ripwire's own honesty
  contract is the argument for the rejection.
- **MCP server mode.** See above; they agree with us.
- **PageRank, BM25 `locate`, embedding search.** Their measurements support
  keeping these deferred.
- **Their headline numbers, for any purpose.** 58.3 percent strict file@10 and
  "5 percent of a grep-and-read pass" are self-run, on Python-dominant
  LocBench slices plus C++ and JavaScript corpora. No Dart. Their own C++
  number is 28.7 percent on SFML and their held-out multi-file localization is
  18.2 percent. Nothing there transfers to a Dart tool.

## Caveats on this assessment

Not built, not run, no benchmark reproduced. Everything about ripwire here is
read from its `README.md`, `docs/EVALS.md`, `SECURITY.md`,
`.github/workflows/release.yml` and the GitHub API. It is six weeks old
(created 2026-07-29), 1,718 of 1,724 commits from one human account plus 6
from `claude`, pre-1.0 with an explicit "No Version Promises" policy, and
about 180 binary downloads against 378 stars. Its methodology is worth
reading; its maturity is not worth depending on. Longer review with full
vitals: `~/projects/logos/findings/repo-reviews/ripwire.md`.
