# codegraph

Analyzer-built code graph + query CLI so AI coding agents can navigate a
Dart/Flutter codebase **without grepping** — plus an `init` command that
installs the agent trigger layer (a `CLAUDE.md` block, a session-start
freshness hook, and a `code-map` skill) into any project.

Answers the questions that otherwise cost an agent many greps and file reads —
"where is class X", "who watches this provider", "what does this file depend
on", "who implements this interface", "how do A and B connect" — in about a
second, with output budgeted to fit an agent's context window.

## Install

```bash
dart pub global activate -sgit https://github.com/ArinFaraj/codegraph
# make sure ~/.pub-cache/bin is on PATH
```

Update later with the same command (or pin a version with `--git-ref v0.x.y`).

**IMPORTANT:** Always invoke the installed `codegraph` binary directly.
`dart run` or `dart pub global run` can interleave pub-resolution output into
stdout (~2s overhead per call), corrupting piped or `--json` usage. Use the
binary from your PATH.

## Set up a project (once)

```bash
cd my_flutter_project
codegraph init          # CLAUDE.md block + hook + skill + LIMITATIONS seed
codegraph init --ci     # also writes a GitHub Actions freshness gate
codegraph build         # generate docs/maps/
codegraph doctor        # verify the install
# commit CLAUDE.md, .claude/, docs/maps/*.md (code_graph.json is gitignored)
```

`init` is idempotent: existing files are skipped, the `CLAUDE.md` block is
marker-guarded, and an existing `.claude/settings.json` is never rewritten
(you get the snippet to add instead).

## Query (what agents run)

Five intent verbs cover the questions agents actually ask - start here:

```bash
codegraph find <anything>      # what/where is X - files, providers, symbols, members (ranked)
codegraph uses <thing>         # who uses X - readers, call sites, subtypes, or importers,
                               #   sections picked by what X resolves to
codegraph change <thing>       # what must change if I touch X - dependents + subtype tree
                               #   + state-type follow-ups + untested-in-blast-radius
codegraph review [--base ref]  # is my branch safe - blast radius, untested, lint violations
codegraph health               # where to start - triage, dead-code and coverage candidates
codegraph plan <feature-dir>   # build-order plan from an exemplar feature
```

Low-level verbs (the intent verbs compose these; all still work directly):

```bash
codegraph brief|sym|skeleton|readers|callers|refs|callchain|wiring|impls|path
codegraph unused|untested|impact|diff|passport|attention|doctor
```

Resolved analysis (v3): `build` uses the analyzer's element model by default
(falls back to syntax-only with no `.dart_tool/package_config.json`; `--syntax`
forces it). Element identity powers three opt-in, resolution-backed answers
(slow - whole-context resolution, the "once in a while" refactor case):

```bash
codegraph callers|refs <Symbol> --resolved   # attribute each call site to its REAL target
                                             #   (HomePage.build vs SettingsPage.build) +
                                             #   the inheritance override chain (safe to change?)
codegraph rename <Symbol|Class.method> <new> # element-precise rename incl. a whole override set;
                                             #   refuses if unsafe/incomplete; --apply to write
```

Every answer ends with its scope caveat (what the graph cannot see), every
not-found states the graph's freshness, and a stale or missing graph rebuilds
itself automatically (~2s; `--no-rebuild` opts out). Exit codes: 0 answered,
2 ambiguous argument (candidates listed), 64 usage, 66 no graph.

For an **interface/method signature change**, the typical workflow is:

```bash
codegraph sym <method>         # what changed (signature across all declarations)
codegraph callers <method>     # who calls it (incl. tests)
codegraph impls <Interface>    # who implements it (incl. test fakes)
codegraph find <field/token>   # lifecycle helpers if a field moved
```

~1s per query. Output is line-budgeted (`--budget N`, default 80) so it fits an
agent's context. The graph spans `lib/` **and** every local package under
`packages/*/lib` (resolved via the host pubspec's `path:` dependencies, so
stray backup copies of a package are excluded); the host package name is read
from `pubspec.yaml`, so no per-project config is needed. Imports, types,
symbols, and test references resolve on any Dart/Flutter codebase — the deep
value (provider wiring, navigation resolution, who-reads-this-provider
queries) is specific to Riverpod + GoRouter codebases; other state/routing
stacks only get the generic graph.

## Review verbs

Branch and code-review actions (verb-only output, never committed artifacts):

```bash
codegraph diff [--base <ref>]   # branch blast-radius: what files changed, providers affected, dependencies broken, untested code touched
codegraph impact <thing>        # transitive dependents: all files/pages that would break if this provider or file changes
codegraph untested              # coverage gaps: all providers and relevant files with zero test references, ranked by impact
```

Example: `codegraph diff` shows a 4-file change touches 12 downstream files and leaves 2 new providers untested. `codegraph impact homeProvider` shows 8 files read it; if you change it, those 8 are affected.

Note: `diff` and `impact` may call git (requires a clean working tree or `--base` arg). Output is verb-only; the data never lives in committed artifacts.

## --json output

Pass `--json` to `find`, `readers`, `wiring`, `impls`, `sym`, `skeleton`,
`untested`, `impact`, or `diff` for machine-readable JSON. Response envelope:

```json
{
  "verb": "find",
  "query": "homeProvider",
  "results": [
    {"name": "homeProvider", "kind": "provider", "file": "lib/features/home/home_controller.dart", "score": "15⇐"}
  ],
  "truncated": false
}
```

Budgets cap the TOTAL results across all sections, so `--budget N` limits the
combined output. Verbs supporting `--json`: `find`, `readers`, `wiring`,
`impls`, `sym`, `skeleton`, `untested`, `impact`, `diff`.

## What the graph captures

Riverpod wiring (provider declarations + `ref.watch/read/listen` edges),
navigation targets (`context.go/push`, `router.go`), the type graph
(extends/implements, resolved to declarations), imports/exports/parts
(including conditional configurations), per-file symbols (classes, enums,
functions), and test references (scanned from test roots). Built with the real
Dart analyzer parser — syntax only, so it needs **no `pub get`** in the host
project and never breaks on unresolvable dependencies.

Because resolution is **syntax-only name matching** (not type resolution), it
is a careful heuristic, not ground truth: it resolves a reference only when the
name is unambiguous or reachability narrows it to one declaration, and refuses
(never guesses) otherwise. Two known coverage limits: provider detection sees
**manually declared** providers (`final xProvider = NotifierProvider(...)`) but
**not `@riverpod` code-generated** ones (the generated `xProvider` lives in an
excluded `.g.dart`); and several nav/role heuristics are tuned to common
Riverpod + GoRouter conventions (`AppPaths.` route chains, `_page.dart` /
`_controller.dart` naming), so a project with different idioms gets the generic
graph plus whatever of the deep layer its conventions happen to match.

### Known query gaps

| Gap | Workaround |
|-----|------------|
| `callers` tracks method *calls*, not field *reads* | `find <field>` or read the declaring class |
| `impact` resolves providers/files, not methods | `callers <method>` + `impls <Interface>` for signature changes |
| OpenAPI / generated DTO field removals | `git diff` on the API package |
| `@riverpod` codegen providers | grep for the generated `*Provider` in `.g.dart` files |

## Artifacts and freshness

- **Commit these:**
  - `docs/maps/*.md` — area maps, INDEX.md, and ATTENTION.md: deterministic,
    regenerated at every `build`, gated by `check()`.
  - `docs/maps/notes/` — human/AI-authored knowledge sidecar, ungated
    (`check()` never diffs it, `build` never writes it). Committed so the
    knowledge persists across machines/sessions. Write notes when you learn
    something non-obvious about an area: `docs/maps/notes/<area-name>.md`.
    `brief <area>` surfaces their first 20 lines; `attention` flags stale notes.
  - `.claude/hooks/code-graph-refresh.sh` — SessionStart hook script.
  - `.claude/skills/code-map/SKILL.md` — code-map skill prompt.
  - `.gitignore` line: `docs/maps/code_graph.json`.
- **Never commit `docs/maps/code_graph.json`** — the entire resolved graph
  (~3.7 MB). Untracked; rebuilt by the SessionStart hook and by CI, not by hand.
  Note: testRefs counts are token/import matching (candidate data — a name in a
  comment counts), same doctrine as `unused` — confirm with grep before acting
  on them. Credit follows direct imports plus their export closure; token
  matching for providers remains candidate data.

- **SessionStart hook** (installed by `init`): mtime check, regenerates only
  if stale, then emits a ~450-token project passport at session start, fail-safe
  `exit 0` on every path. Once per session, zero per-edit cost. Also surfaces
  any notes files found.
- **CI gate** (`init --ci`): `codegraph check` regenerates and fails the build
  if committed `docs/maps/` drifted (excludes notes/ and JSON).
- **Rejected: per-edit (PostToolUse) regen** — seconds of latency on every
  edit for marginal freshness benefit. Don't re-propose it; see
  `CHANGELOG.md`.

## Roadmap

Execution-ready plans for the next releases live in [`plans/`](plans/) —
0.6.0 "Trust" (nav-gap legibility, registry-resolved testRefs, doctor,
summary-only maps), 0.7.0 "Lint" (the graph becomes a CI-enforced
architecture gate with a baseline ratchet), 0.8.0 "Leverage" (affected-tests
selection, change risk score, Riverpod health rules). See
[`plans/ROADMAP.md`](plans/ROADMAP.md) for ordering and the standing
doctrine.

## The improvement loop

Every installed project's `code-map` skill and `docs/maps/LIMITATIONS.md`
point back here. When the graph is wrong in any project:

1. Log the gap in that project's `docs/maps/LIMITATIONS.md` (a dated line,
   generic wording — no product or vendor SDK names).
2. Fix the engine here — `lib/src/engine.dart` (extraction) or
   `lib/src/query.dart` (queries). Add a `CHANGELOG.md` line. Tag if you want
   pinning (`git tag v0.x.y`).
3. Update the CLI everywhere it's installed:
   `dart pub global activate -sgit <this repo>` (add `--git-ref v0.x.y` to
   pin).
4. `codegraph build` in the affected project.
5. Review `docs/maps/LIMITATIONS.md` in each host — merge any new known gaps
   from the release notes (`upgrade` refreshes the skill but never overwrites
   LIMITATIONS).

Design decisions live in `CHANGELOG.md`, including rejected ideas — check it
before "improving" the tool back into rejected territory.

## Development

```bash
dart pub get
dart analyze
dart test
```

## License

MIT — see [LICENSE](LICENSE).
