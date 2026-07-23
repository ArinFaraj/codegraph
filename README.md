# codegraph

Analyzer-built code graph + safe-change CLI for Dart/Flutter codebases. It
gives AI coding agents a resolved model of the project, answers structural
questions without reconstructing the codebase from grep, and can emit or apply
element-precise renames while refusing changes it cannot prove safe. An `init`
command installs the agent trigger layer (a `CLAUDE.md` block, a session-start
freshness hook, and a `code-map` skill) into any project.

Answers the questions that otherwise cost an agent many greps and file reads —
"where is class X", "who watches this provider", "what does this file depend
on", "who implements this interface", "how do A and B connect" — in a
subsecond native command, with output budgeted to fit an agent's context window.

## Install

```bash
dart pub global activate -sgit https://github.com/ArinFaraj/codegraph
~/.pub-cache/bin/codegraph install-native
# make sure ~/.local/bin is on PATH before ~/.pub-cache/bin
```

Update later with the same command (or pin a version, for example
`--git-ref v3.7.0`), then rerun `~/.pub-cache/bin/codegraph install-native`.

Pub's generated launcher invokes `dart pub global run` on every command. On the
1,578-file KRDPass benchmark that launcher took 1.22-1.33s and peaked near
294MB for an already-cached query; the installed native executable took
0.13-0.16s without a daemon. It still discovers the Dart SDK from `dart` on
PATH for resolved analysis and falls back to syntax-only when no SDK is
available. Always invoke the native `codegraph` from `~/.local/bin`; reserve
the pub launcher for installing or updating that executable.

## Set up a project (once)

```bash
cd my_flutter_project
codegraph init          # CLAUDE.md block + hook + skill + LIMITATIONS seed
codegraph init --ci     # also writes a GitHub Actions freshness gate
codegraph build --syntax # generate fast navigation maps
codegraph daemon         # optional event-driven workspace worker
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
codegraph affected-tests       # explain targeted tests; uncertainty expands to full suites
codegraph health               # where to start - triage, dead-code and coverage candidates
codegraph plan <feature-dir>   # build-order plan from an exemplar feature
codegraph route <RouteData>    # full typed route card: placements/paths,
                               #   parent/shell/branch, navigator, page, redirect, callers
```

Low-level verbs (the intent verbs compose these; all still work directly):

```bash
codegraph brief|sym|skeleton|readers|callers|refs|callchain|wiring|route|impls|path
codegraph unused|untested|impact|diff|affected-tests|passport|attention|doctor
```

Resolved analysis (v3): `build` uses the analyzer's element model by default
(falls back to syntax-only with no `.dart_tool/package_config.json`; `--syntax`
forces it). Element identity powers three opt-in, resolution-backed answers.
A resolved build persists their identities, so normal calls are graph-speed;
a fresh whole-context analyzer walk remains the compatibility fallback:

```bash
codegraph callers|refs <Symbol> --resolved   # attribute each call site to its REAL target
                                             #   (HomePage.build vs SettingsPage.build) +
                                             #   the inheritance override chain (safe to change?)
codegraph rename <Symbol|Class.method> <new> # element-precise rename incl. a whole override set;
                                             #   refuses if unsafe/incomplete; --apply to write
```

Every answer ends with its scope caveat (what the graph cannot see), every
not-found states the graph's freshness, and a stale or missing graph rebuilds
itself automatically. Normal navigation uses the fast syntax graph; only
`route`, `rename`, `affected-tests`, and `callers|refs --resolved` pay for
whole-workspace element resolution (`--no-rebuild` opts out). Exit codes: 0 answered,
2 ambiguous argument (candidates listed), 64 usage, 66 no graph.

## Optional workspace daemon

`codegraph daemon` is a singleton background worker for the current workspace.
It watches source changes, debounces save bursts, and refreshes the untracked
syntax graph before the next query. Fresh commands reuse its state through a
local loopback socket instead of walking every source file; an exclusive
workspace reservation and build lock prevent duplicate workers and build
races. Use `codegraph daemon status` or `codegraph daemon stop` to inspect it.

It intentionally does **not** start another long-lived resolved analyzer beside
your IDE's Dart language server. Element-precise `route`, `rename`,
`callers|refs --resolved`, and the safety-critical `affected-tests` plan retain
their existing one-shot, refusal-safe analysis.

This is event-driven background refresh, not a retained whole-project analyzer
or a claim of per-file incremental parsing. On the KRDPass benchmark it used
0.0% CPU while idle, roughly 55-64MB RSS with a 91MB observed peak, and reduced
a hot native query from 130-160ms to about 80ms. The larger win is
moving the 1.7s syntax refresh off the first query after an edit. Stop it when
you prefer zero resident cost; correctness falls back to the one-shot path.

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
codegraph affected-tests        # complete package/runner test plan with evidence and fail-open expansion
codegraph impact <thing>        # transitive dependents: all files/pages that would break if this provider or file changes
codegraph untested              # coverage gaps: all providers and relevant files with zero test references, ranked by impact
```

Example: `codegraph affected-tests --base main` connects changed production
files to runnable `*_test.dart` entrypoints through imports, provider
interactions, test helpers, and parts. Deleted files, configuration/generated
boundaries, stale graphs, parse errors, unknown paths, and empty production
selections expand to workspace suites instead of silently skipping tests.
When a tracked Git hunk is wholly inside the same executable body before and
after the change, the resolved index follows that exact symbol through callers,
overrides, test helpers, and test entrypoints. Sibling tests that merely import
the same file can then be excluded from the recommended first pass. Signature,
directive, generated-provider, dynamic-dispatch, and framework-override changes
fall back to file/workspace coverage and are reported in `precisionFallbacks`.

Note: `diff` and `impact` may call git (requires a clean working tree or `--base` arg). Output is verb-only; the data never lives in committed artifacts.

## --json output

Pass `--json` to `find`, `readers`, `wiring`, `route`, `impls`, `sym`, `skeleton`,
`untested`, `impact`, `diff`, or `affected-tests` for machine-readable JSON.
Affected-test plans are never budget-truncated because their selected paths and
argv arrays are executable contracts. Other verbs use the standard envelope:

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
`route`, `impls`, `sym`, `skeleton`, `untested`, `impact`, `diff`,
`affected-tests`.

## What the graph captures

Riverpod wiring (manual and source-declared `@riverpod` providers plus
`ref.watch/read/listen/invalidate/refresh` edges),
navigation targets (`context.go/push`, `router.go`, and resolved typed-route
`.go/.push/.replace/.pushReplacement/.goRelative/.pushRelative` calls), the
resolved typed GoRouter annotation tree (nested path patterns, reusable
relative-route placements, shell/stateful branch ownership, navigator keys,
direct pages, static redirect destinations, and callers), the type graph
(extends/implements, resolved to declarations), imports/exports/parts
(including conditional configurations), per-file symbols (classes, enums,
functions), and test references (scanned from test roots). With a host
`.dart_tool/package_config.json`, `build` uses the Dart analyzer's resolved
element model by default. Without it, codegraph automatically uses its
zero-setup syntax path; `--syntax` forces that path explicitly. A single file
that cannot resolve falls back independently instead of breaking the build.

The graph records confidence rather than presenting every edge as ground
truth: element-confirmed facts are `resolved`, conservative name/reachability
matches are `heuristic`, and inferred navigation facts are `guessed`. Safe
write operations act only on a complete resolved target and refuse otherwise.
Resolved builds recognize `@riverpod` functions and Notifier classes by the
annotation element's `package:riverpod_annotation` identity, deriving the
generated provider name, kind, lifecycle, and interaction edges without
reading excluded `.g.dart` files. Syntax-only builds retain manual-provider
coverage. Resolved builds also connect real `GoRouteData`/`RelativeGoRouteData` receiver
calls to pages returned directly by `build` or `buildPage`, while refusing fake
bases, dynamic receivers, conditional bodies, and ambiguous pages.
`codegraph route <RouteData>` is resolved-only and fails closed when the route
index is unavailable or incomplete; it never fabricates one canonical path for
a relative route used in several placements. One important limit remains:
several raw navigation and role heuristics
are tuned to common Riverpod + GoRouter conventions (`AppPaths.` route chains,
`_page.dart` / `_controller.dart` naming), so projects with different idioms
receive the generic graph plus only the deep facts Codegraph can prove.

### Known query gaps

| Gap | Workaround |
|-----|------------|
| `callers` tracks method *calls*, not field *reads* | `find <field>` or read the declaring class |
| `impact` resolves providers/files, not methods | `callers <method>` + `impls <Interface>` for signature changes |
| OpenAPI / generated DTO field removals | `git diff` on the API package |
| Global `GoRouter.redirect`/`onEnter`, runtime redirect outcomes, and custom navigator containers | `route` shows statically exact route-level redirects and resolved navigator ownership; inspect router construction for global policy |

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
  - `.gitignore` lines: `docs/maps/code_graph.json` and
    `docs/maps/refactor_index.json`.
- **Never commit the generated JSON indexes** — the graph and resolved
  refactor identities are workspace caches. They are rebuilt by the
  SessionStart hook and by CI, not maintained by hand.
  Note: testRefs counts are token/import matching (candidate data — a name in a
  comment counts), same doctrine as `unused` — confirm with grep before acting
  on them. Credit follows direct imports plus their export closure; token
  matching for providers remains candidate data.

- **SessionStart hook** (installed by `init`): mtime check, regenerates only
  if stale with the fast syntax extractor, emits a ~450-token project
  passport, then starts the singleton event-driven worker. It is fail-safe
  (`exit 0` on every path) and also surfaces notes files.
- **CI gate** (`init --ci`): `codegraph check` regenerates and fails the build
  if committed `docs/maps/` drifted (excludes notes/ and JSON).
- **Rejected: synchronous per-edit (PostToolUse) regen** — seconds added to the
  edit path for marginal freshness benefit. The daemon is different: filesystem
  events are debounced and refresh the untracked index asynchronously.

## Roadmap

v3.0 is shipped: resolved analysis is now the default, element identity powers
precise `callers`/`refs`, and `rename` is the first guarded write actuator.
Resolved builds now persist refactor identities, so repeated safe renames avoid
whole-workspace reanalysis. The next milestone is indexed callers/refs plus
high-signal conformance rules, measured by the public deterministic benchmark.
See [`plans/ROADMAP.md`](plans/ROADMAP.md) for current priorities and doctrine.

## The improvement loop

Every installed project's `code-map` skill and `docs/maps/LIMITATIONS.md`
point back here. When the graph is wrong in any project:

1. Log the gap in that project's `docs/maps/LIMITATIONS.md` (a dated line,
   generic wording — no product or vendor SDK names).
2. Fix the engine here — `lib/src/engine.dart` (extraction) or
   `lib/src/query.dart` (queries). Add a `CHANGELOG.md` line. Tag if you want
   pinning (`git tag v3.x.y`).
3. Update the CLI everywhere it's installed:
   `dart pub global activate -sgit <this repo>` (add `--git-ref v3.x.y` to
   pin, for example `--git-ref v3.0.0`).
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
