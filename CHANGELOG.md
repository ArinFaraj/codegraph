# Changelog

The v3 changelog, plans and benchmarks are in [`archive/v3/`](archive/v3/).
The reasoning behind v4 is in [`docs/rewrite-plan.md`](docs/rewrite-plan.md).

## 4.1.0 - 2026-10-19

A restructuring after a hard review of 4.0.0. The answers on a 3,380-file
Flutter app are the same; several get much faster, and two JSON shapes
change.

### Changed

- The resolved verbs work on elements end to end. Each use keeps the
  analyzer's enclosing element, so `impact` finds dependents directly instead
  of matching the outline by line and name and looking the result up again.
  `impact` of a file went from 17.6s to 1.1s, of a symbol from 2.2s to 0.4s,
  and a rename dry run from about 1.2s to 0.2s.
- `path.dart:LINE` means the outermost declaration named on that line, read
  from the resolved unit. A one-line `enum E { a, b }` resolves to the enum.
- One declaration walker serves both the parse-only outline and the resolved
  engine, so the two cannot disagree about what a file declares.
- Every verb returns a typed answer that writes both its text and its JSON.
  `impact --json` now reports `direct` and `secondStep` without test files
  (they are under `tests`), matching the text. `show <provider> --json`
  includes `readers`.
- `show` and `impact` decide once, in the client, whether an argument is a
  file, a directory or a symbol.
- Transitive subtype lists stop at 500 and now say so with a `partial:` line.
- The worker keeps one engine for its lifetime and refreshes the outline and
  source cache from the analyzer's change list, instead of reloading the
  outline from disk on each request.
- Rename is a plan step and an apply step. Refusals are typed (`UNSAFE`,
  `UNSUPPORTED`) and no longer travel as exceptions.

### Internal

- Paths are workspace-relative everywhere outside `analysis.dart`.
- Riverpod knowledge lives in `riverpod.dart`.
- The worker receives typed requests instead of re-parsing argv, which
  removes the import cycle between the CLI and the worker.
- The global test seams are gone: tests withhold an edit between planning and
  applying a rename.
- `tool/lsp_diff.dart` finds a declaration's column by word boundary, and
  accepts `show`/`hide` combinators that codegraph lists and the language
  server omits (it reports them for classes and variables, not getters).

## 4.0.0 - 2026-10-19

A rewrite. codegraph stops generating files, gating CI and installing
scaffolding, and becomes one thing: exact answers about a Dart or Flutter
repository, from the Dart analyzer, as the files are on disk now. Nothing is
compatible with v3; every removed verb names its replacement when called.

### What it is now

- Six verbs: `find`, `show`, `refs`, `impact`, `rename`, `why`, plus `doctor`.
- `find`, `show <file>`, `show <dir>` and `why` parse source and answer in
  about 0.2s with no analyzer, from a cache in `.dart_tool/codegraph/`.
- `refs`, `impact`, `rename` and `show <symbol>` are answered by a background
  worker per checkout that keeps the analyzer and its search index warm,
  syncs every analyzed file with the disk before each answer, exits after 20
  idle minutes, and never runs more than two at once on a machine.
- Coverage is exactly what `dart analyze` sees: `lib/`, `test/`,
  `integration_test/`, `tool/` and path packages, with `analysis_options.yaml`
  excludes honored.

Measured on a 3,380-file Flutter app (warm analyzer cache): ready about 10s
after a restart, 30s from an empty cache; repeat references for a provider
with 331 uses in 65ms; a body edit reflected in under a second; a verified
rename (15 edits, 47 files re-analyzed) in 1.7s. On 300 sampled declarations
of that app, `refs` agrees with the Dart language server once the server has
finished analyzing.

### Correctness fixes over v3

- Subtypes come from the element model. v3 read `extends`/`implements` text,
  so `enum X implements Y` and `with` mixins were missing and an interface
  implemented only by enums reported "no subtypes".
- Provider readers are exact references classified by role. v3's everyday
  graph was syntax-only and missed reads through a ref held in a field
  (`deps.ref.read(p)`); it also counted per file, not per line.
- Name matching is gone: `refs build` no longer merges every `build` in the
  repository; an ambiguous name lists its candidates (exit 2).

### Rename

- Every element kind: fields with their getter, setter, `this.x` and
  `super.x` parameters and the named arguments that pass them, static fields,
  methods with their whole override set (test fakes included), classes with
  their constructor declarations, enum values, top-level variables and
  providers, parameters.
- It refuses to compute until the workspace is fully analyzed. The Dart
  language server, asked too early, returned 9 of 15 edits for a static field
  rename with no sign the answer was partial.
- Every edit is checked against the text on disk. `--apply` installs the
  edits in one staged step, re-analyzes the edited files and their importers,
  and restores every file if an error appeared.
- Refusals are `UNSAFE` (dynamic calls to the name, framework overrides, code
  generation annotations, public API of a publishable path package, privacy
  changes, collisions) or `UNSUPPORTED` (files, unnamed constructors), and
  the message says which.
- Dry runs warn about string literals spelling the old name, enum names that
  may be stored as data, and edits to generated files.

### Removed

- Committed maps (`docs/maps/*.md`, `INDEX.md`, `ATTENTION.md`), `build`,
  `check`, the CI freshness gate and its pre-push hook. Repositories using
  them should delete them; notes in `docs/maps/notes/` are still read by
  `show <dir>`.
- `lint` and `lint-baseline.json`. Architecture rules belong in the
  repository's own tests, which run where CI is watched.
- `init`, `upgrade`, version-stamped scaffolding and the skew warning. The
  agent block and skill in [`docs/agents.md`](docs/agents.md) carry no
  version.
- The v3 daemon, the syntax graph, `refactor_index.json`, the session
  passport, the PR diff comment, and the verbs `brief`, `sym`, `skeleton`,
  `wiring`, `uses`, `readers`, `provider`, `callers`, `impls`, `path`,
  `change`, `review`, `diff`, `affected-tests`, `callchain`, `health`,
  `attention`, `unused`, `untested`, `plan`, `blueprint`, `trace`, `route`,
  `passport`.

### Known limits

- `impact` lists the tests that reference a change within two steps. It is
  not a guaranteed test plan; run the full suite before pushing.
- Typed GoRouter route topology (the v3 `route` card) is not rebuilt yet;
  `refs` and `show` cover route classes as ordinary classes.
- File renames and unnamed constructors are `UNSUPPORTED`.
- The analyzer cache must not be shared between checkouts: entries are keyed
  by content but some carry paths, and a cache filled by a checkout at another
  path silently drops references. codegraph keeps one per checkout.
