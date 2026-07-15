# What a perfect code knowledge / brain system looks like (and codegraph's model toward it)

Status: research + model design, 2026-07-14. Companion to plans/BRD-actuator.md.
The BRD says WHAT to build and in what order; this file says WHAT THE
KNOWLEDGE ITSELF should be - the data model codegraph's graph evolves into once
the v3 "no byte-compat" freedom lets the model change shape, not just gain
accuracy on the old shape.

## 1. The reframe: a graph is not the goal, a brain is

codegraph today is a single-layer property graph: mostly file and provider
nodes, a handful of edge kinds (imports, watch/read/listen, subtype,
navigates), name-matched. That is one layer of one kind of memory. The state
of the art in code-understanding systems is not "a bigger graph" - it is a
LAYERED MEMORY system that separates kinds of knowledge and retrieves across
them.

The AI-agent-memory field converged in 2025-2026 on a three-tier taxonomy
borrowed from cognitive science: episodic, semantic, and procedural memory
(mem0, Cognee, Zylos). Mapped onto a codebase, that is exactly the structure a
useful code brain needs:

- SEMANTIC memory - what the code IS and how it connects (facts, timeless):
  symbols, types, references, call graph, data flow. The property graph.
- EPISODIC memory - what HAPPENED to the code (events, time-stamped): commits,
  PRs, who changed what and why, what changes together. Git is an untapped
  episodic store.
- PROCEDURAL memory - how to ACT on the code safely (skills): how to change X,
  what breaks, what invariants hold, what edit a refactor needs. This is the
  actuator, and it is the pillar that makes a brain useful rather than
  encyclopedic.

Two faculties cut across all three:

- ATTENTION / salience - what matters RIGHT NOW for the task at hand. Not
  static importance; relevance to the current focus.
- CONFIDENCE / provenance - how much to trust each fact: resolved, heuristic,
  or guessed. In a system whose doctrine is "a wrong edge is a blocker," this
  cannot be a footnote - it must be a column on every node and edge.

The rest of this doc makes each layer concrete for codegraph and grounds it in
the systems that already do pieces of it well.

## 2. The semantic core: a resolved, multi-granularity property graph

The reference design for "one queryable graph that answers deep questions" is
the Code Property Graph (CPG), from Joern: it merges three representations into
one graph - the AST (structure), the CFG (control flow), and the PDG (program
dependence = data-dependence + control-dependence) (cpg.joern.io). "Who calls
X" needs the call graph; "where does this value flow / what breaks if it
changes" needs the PDG. The 2025-2026 frontier is explicitly CPG + LLM: recent
work guides LLM vulnerability detection with CPG context (LLMxCPG,
arxiv 2507.16585) and bridges CPGs to language models for program analysis
(arxiv 2603.24837). A code brain's semantic core IS a CPG, built incrementally:

Granularity - stop being file+provider-centric. Nodes at every level the
analyzer's element model exposes: file, class/mixin/enum/extension,
method/function/constructor, field/top-level-var, parameter, provider (a
Riverpod specialization of a variable). Coarse file nodes stay as containers;
the fine nodes are where reasoning happens.

Stable identity - give every node a human-readable symbol id, not an opaque
number. Sourcegraph's SCIP learned this the hard way migrating off LSIF:
human-readable string monikers (e.g. a symbol string encoding package + path +
descriptor like `Class#method().`) made indexers simpler and debugging
tractable, and they make cross-repo/monorepo navigation fall out for free
(scip-code.org, sourcegraph.com/blog/announcing-scip). codegraph's `elementId`
should be a SCIP-style symbol string derived from the resolved element, not a
file:line. Same symbol across two packages = same id = cross-package "who uses
this" with zero extra work.

Edge kinds, layered onto the same nodes (build in this order):
1. structural: declares/contains (file -> class -> method -> param).
2. reference/type (Stage 2 of 3.0): calls (resolved), references, extends,
   implements, overrides, has-type. Riverpod watch/read/listen become typed
   reference edges whose receiver static type is Ref/WidgetRef/Container.
3. dependence (later, the CPG payoff): data-flow (this param flows to that
   return, this field is written here / read there), reachability from source
   to sink. This is what "where does this value go" and trustworthy refactor
   blast-radius need.

## 3. Confidence as a first-class column (the honesty doctrine, promoted)

codegraph's strongest existing idea is NEVER-GUESS: a wrong edge is a blocker,
a missing one is fine. Today that lives in prose and refusal gates. In the new
model it becomes DATA: every node and edge carries a provenance/confidence
tag - resolved (element identity), heuristic (name/token match), or guessed
(inferred, e.g. a nav target through a constant). Consequences:

- queries can filter: "who calls X, resolved only" for a safe refactor vs
  "any mention" for exploration.
- the actuator (procedural layer) refuses to emit an auto-edit against anything
  below `resolved`, by construction - the refusal gate is a WHERE clause, not
  bespoke code per verb.
- honesty is measurable: the fraction of resolved vs heuristic edges is a
  quality metric that trends as resolution improves.

This is the single most differentiating property versus every tree-sitter-based
competitor (Aider's repo map, the Codebase-Memory MCP KG, arxiv 2603.27277):
they are syntactic and cannot tell a real reference from a same-named token.
codegraph can, and it can PROVE which is which per edge.

## 4. Episodic layer: git as memory the graph never had

The graph knows the code's current shape and nothing about its life. Git is a
free, rich episodic store the model should attach as fact layers on the semantic
nodes:

- co-change coupling: symbols/files that change together in commits (often a
  stronger "these are related" signal than an import edge - reveals hidden
  coupling the type graph cannot see).
- churn / hotspots: change frequency per node (risk and attention input).
- ownership / recency: who last touched this, how old is it (triage, review
  routing).
- provenance of a fact: "this edge was introduced in commit/PR N" - the "why".

Kept honest per doctrine: episodic facts live in VERB output and an ungated
sidecar, never in the deterministic committed graph (git/wall-clock stay
verb-only, as today). This is a fact layer queried on demand, not baked into
`code_graph.json`.

## 5. Procedural layer: knowledge that acts (the actuator)

The three memory tiers are not equal in value. Semantic + episodic make a great
encyclopedia; procedural is what makes a brain. This is the BRD's P2 actuator
and P1 conformance, restated as memory:

- change-safety: given a target symbol, the resolved edit-set to change it
  without breaking the build (every override, call site, tear-off), each with
  the edit. Built on the reference+dependence layers, gated on `resolved`
  confidence.
- invariants: codified architectural rules (layering, pairing, must-stay-in-
  sync) checked over the whole graph - the conformance guardrail.
- "how do I": build-order plans from exemplars (codegraph's existing
  `blueprint`), generalized.

Procedural knowledge is the answer to "useful for USERS even," not just AI: a
human asking "is it safe to change this" or "what's the blast radius" wants the
procedural layer, rendered as a navigable answer, not a raw graph.

## 6. Retrieval: two audiences, hybrid, budgeted, salient

A brain is only as useful as its recall. Two design facts from the field:

- Hybrid beats pure-vector and pure-graph. The 2025-2026 consensus (Cognee,
  mem0): vector search finds entry points, graph traversal follows the
  dependency chains from them. codegraph is pure-graph today; an optional
  embedding index over symbols/docs would let a fuzzy natural-language question
  ("where's the retry logic") find seed nodes, then the resolved graph does the
  precise traversal. Graph stays the source of truth; embeddings are just a
  fuzzy front door. (Gated on evidence of need - do not build speculatively.)

- Salience must be PERSONALIZED, not static. Aider's repo map is the reference:
  a def/ref symbol graph ranked by personalized PageRank toward the files in
  the current conversation, rendered to a token budget by binary search, with
  edge-weight multipliers for mentioned and well-named identifiers
  (aider.chat/2023/10/22/repomap.html). codegraph's `attention` uses static
  in-degree; the upgrade is personalized ranking - "important RELATIVE to the
  symbols I'm touching now" - which is what an agent actually needs when it
  lands in a task.

Two output modes, one model:
- for AI: budgeted, composable slices with confidence tags, and apply-ready
  edit-sets (the actuator). codegraph's existing strength.
- for humans: navigable maps and visualization - the same layered graph
  rendered for a person (area maps today; a real graph view later).

## 7. Concrete model changes for codegraph (v3, no byte-compat)

Freed from byte-identical, the wire format changes shape:

- GraphNode gains `symbolId` (SCIP-style resolved string) and a `kind` widened
  to method/field/param, not just file/provider. Fine nodes are additive; file
  nodes stay as containers.
- GraphEdge gains `confidence` (resolved | heuristic | guessed) and typed
  `kind` extended with calls/overrides/has-type (and later data-flow).
- graphFormatVersion bumps freely; OLD GRAPHS DO NOT NEED TO LOAD - a stale
  graph rebuilds itself. Drop the additive-only-with-pinned-positions
  contortions from 2.x; the loader can simply reject a pre-v3 format and
  trigger a rebuild.
- Determinism stays for the SAME source (check() gate, caching) - that is
  byte-determinism of a build, which we keep. What we drop is byte-COMPATIBILITY
  with the old schema. Those are different: same-source-same-bytes is a
  feature; same-bytes-as-last-year is a cage.

Non-negotiables carried forward: NEVER-GUESS (now a confidence column),
budgeted output, syntax fallback for zero-setup and per-file resolution
failure, no LLM output in the committed deterministic graph.

## 8. Sequencing (folds into the BRD pillars)

The layered brain is not a rewrite; it is the BRD pillars, re-understood:

1. 3.0 Stage 2 (now): reference/type layer with element identity + the
   `confidence` column + `symbolId`. The semantic core's second layer, honestly
   tagged. THIS is where the model redesign starts landing.
2. P1 conformance: the first procedural layer (invariants over the graph).
3. Dependence layer (data-flow) + P2 actuator: the CPG payoff and the
   change-safety skill - the procedural core.
4. Episodic layer (git facts) and personalized salience: attach once the
   semantic core is resolved; both are fact/ranking layers, not schema rewrites.
5. Hybrid embedding front-door: only on evidence a natural-language seed step is
   needed; the resolved graph is always the source of truth.

## Sources
- Code Property Graph / Joern: https://cpg.joern.io/ ,
  https://docs.joern.io/export/
- CPG + LLM frontier: https://arxiv.org/pdf/2507.16585 (LLMxCPG),
  https://arxiv.org/html/2603.24837v1 (Bridging CPGs and LMs)
- SCIP symbols/monikers: https://scip-code.org/ ,
  https://sourcegraph.com/blog/announcing-scip
- AI agent memory taxonomy (episodic/semantic/procedural), hybrid retrieval:
  https://mem0.ai/blog/state-of-ai-agent-memory-2026 ,
  https://www.cognee.ai/blog/guides/ai-coding-agent-persistent-codebase-memory ,
  https://zylos.ai/research/2026-04-05-ai-agent-memory-architectures-persistent-knowledge/
- Tree-sitter codebase KG (the syntactic baseline codegraph beats):
  https://arxiv.org/html/2603.27277v1
- Aider repo map (personalized PageRank to token budget):
  https://aider.chat/2023/10/22/repomap.html
