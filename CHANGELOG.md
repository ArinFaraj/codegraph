# Changelog

The v3 changelog, plans and benchmarks are in [`archive/v3/`](archive/v3/).
The reasoning behind v4 is in [`docs/rewrite-plan.md`](docs/rewrite-plan.md),
and the plan that 4.3.0 starts is [`docs/v5-plan.md`](docs/v5-plan.md).

## 4.6.0 - 2026-10-20

### Changed

- `show <file>` and `show <dir>` are answered by the worker from resolved
  data. A file lists the providers it declares and every provider use with
  its role; a directory counts, for each provider it declares, the files
  outside it that use it, and lists the providers it reads from elsewhere.
  These used to match names, so two classes called `NetworkFailure` shared
  one count (46 files where the right answer was 6).
- `show <dir>`'s "most used outside" ranking by name is replaced by "imported
  from outside": the area's files with how many files outside import them,
  from the import graph. JSON: `usedOutside` and `mentionedBy` give way to
  `providers[].usedOutside` and `importedFromOutside`.
- The outline holds only declarations and directives. Identifier and string
  word sets, syntactic provider uses and guessed `@riverpod` providers are
  gone (a generated provider is found in its `.g.dart` file); the cache is a
  third smaller and a cold `find` takes 0.1s instead of 0.8s. `find` labels a
  provider by its syntax, `variable`.
- An applied rename or move checks every file that depends on what it
  edited, transitively, as `check` does. It used to check the edited files
  and their direct importers, so a rename that broke a file seeing it only
  through an export was kept. Only errors beyond the earlier count roll it
  back, and only those are listed.
- A running worker is recorded once, in `~/.cache/codegraph/workers/`;
  `.dart_tool/codegraph/worker.json` is gone. A worker from an earlier
  version is stopped and replaced on the next call.

### Fixed

- `path.dart:ClassName` named both the class and its unnamed constructor.
- `doctor` named the removed `impact`; rename's refusal for a library said
  files cannot be moved; the `UNSUPPORTED` footer pointed at `dart analyze`
  instead of `codegraph check`.
- The release comparison's provider filter compared an enum with a string
  and excluded nothing; it is removed, as earlier runs already included
  providers.

## 4.5.2 - 2026-10-20

### Fixed

- A worker that answered a query before `slang.yaml` existed, or before the
  generated strings file was indexed, never found translation keys until it
  restarted. A build that finds nothing is no longer kept, and the index is
  rebuilt when `slang.yaml` reads differently.
- A non-string value in `slang.yaml` made the query fail instead of falling
  back to slang's default.
- `check --all` missed analyzer plugins enabled through an `include:`. The
  names now come from the analyzer's own merged options.

### Changed

- The suggested hooks are one-line commands with no script in the
  repository: they skip machines without codegraph and run from the project
  directory. They carry no version check, so they keep working across major
  versions.
- Translation keys are one object the engine forwards to, instead of state
  and branches inside the engine.

## 4.5.1 - 2026-10-20

### Fixed

- `check --all` named riverpod_lint and said CI runs it in every repository.
  It now names the analyzer plugins the workspace's `analysis_options.yaml`
  enables, top-level or legacy, says `dart analyze` runs them, and prints
  nothing when there are none. JSON carries them as `pluginsNotRun`.

## 4.5.0 - 2026-10-20

### Added

- `refs` and `show` take a slang translation key, dotted or as Dart reads it
  (`t.update.restart`). The key resolves exactly through the generated getter,
  whose body carries it, and the answer adds the key's line in each locale
  YAML file and names the locales missing it. Translation strings were 6 to 9%
  of all greps in the reference app's agent sessions. Needs
  `translation_overrides: true` in `slang.yaml`; YAML locale files only.

## 4.4.0 - 2026-10-20

### Added

- `show <symbol>` prints the declaration's source with line numbers, up to 60
  lines. Half of all lookups in the reference app's agent sessions were
  followed by reading the file they found.
- `show` and `refs` answer each declaration when a name matches up to five,
  instead of exiting 2 with a list.
- `refs -C N` prints N lines of source around each use.
- The worker saves its `check` ledger when it stops and reloads it on the
  same commit, within a day.

### Changed

- `find`, `show <file>` and `show <dir>` are answered by a ready worker from
  memory (0.1s on the reference app, against 0.8s from the cache).
- `find` no longer prints "N files mention it": the count was by name, so
  every field called `gate` showed the same number.
- `check --hook` never waits for a worker to start. It notes the call's
  writes, starts the worker in the background and returns; the first call
  after warm-up checks them. A cold hook call took up to 11s before.
- Warm-up runs one symbol lookup before reporting ready, which moves about 5s
  off the first `refs` or `show` of a session.

### Removed

- `why` and `impact`, used about ten times each in the reference app's
  sessions. `show <file>` lists imports and importers, `refs` lists uses,
  `check` says what a change broke; calling either names the replacement.

## 4.3.0 - 2026-10-20

### Added

- `check [files...]` reports the problems a change introduced, in the
  changed files and everything depending on them, against a ledger of what
  each file had before. `check --all` lists every problem `dart analyze`
  reports, except analyzer plugins. On the reference app (3,391 files),
  `check --all` takes about 2 seconds against 55 for `dart analyze`, and
  prints the same problems once riverpod_lint's are set aside.
- `check --hook` runs after an agent's tool calls: Edit and Write by the
  file they name, shell commands by the files modified while they ran.
  Silent unless something new broke, then the problems on stderr and exit 2.
- Problems follow `dart analyze`: each file's own analysis options
  (`errors:` severities and `ignore`), no TODOs, and pubspec validation.

### Changed

- Rename and move compare errors after the same filtering, so an error code a
  package's options ignore no longer blocks or rolls back a change.

## 4.2.0 - 2026-10-19

### Added

- `rename <file.dart> <new/path.dart>` moves a file. Every import, export
  and conditional import that points at it is rewritten, keeping `package:`
  URIs where the new location allows and recomputing relative ones,
  including the moved file's own. Applying re-analyzes the moved file and
  every rewritten file and puts everything back, file and directories
  included, if an error appears or the new path is not analyzed. Libraries
  with parts are `UNSUPPORTED`. On the reference app, moving a file imported
  from 28 files and back left the tree as it was.

### Changed

- Declaration kinds, directive kinds and use roles are enums shared by the
  parse-only and resolved halves, so `find` and `show` now use the same
  labels (`enum value`, `extension type`) and the role display order is the
  enum's order.
- One `FileTracker` decides which files are analyzed and what changed, for
  both the CLI's outline cache and the worker. It also notices
  `pubspec.yaml`, `analysis_options.yaml` and package config changes, which
  restart the worker's analyzer and rescan the CLI's file list.
- `Workspace.relative` refuses paths outside the workspace; code that can
  meet one uses `relativeOrNull`.
- The parse-only verbs are one file each (`find`, `show_file`, `why`), with
  argument classification in `args.dart`.
- Each verb defines its own worker request; the decoder is one line per
  verb.
- `find` and `show <dir>` count mentions from an index built once, and the
  rename string-literal warning reads only files whose string literals
  contain the word.
- The verify-and-roll-back step is shared by rename and move.

### Removed

- The v3 test hooks and the unused `ioFailure` flag in the edit installer.

## 4.1.1 - 2026-10-19

A second review pass. Answers are unchanged on the reference app; one hole
in rename is closed.

### Fixed

- A rename refuses when a class hierarchy behind it has more than 500
  subtypes. The subtype walk stops there, and the override set or the
  `super.x` parameters it feeds could have been incomplete. A missed override
  still compiles, so the post-apply check could not catch it.
- `show` and `impact` label an answer `partial:` whenever a subtype walk
  behind it stopped early, not only for the subtype list itself.

### Internal

- Each resolved verb is one file holding its computation and its answer
  (`refs.dart`, `show.dart`, `impact.dart`, `rename.dart`); the engine keeps
  only state and the queries they share.
- Resolving a query goes through one `withTarget` helper, and a lookup that
  does not find exactly one declaration is a typed `Unresolved`, so no verb
  casts the result.
- Rename refusals are a list of rules, one function each.
- `impact` seeding returns one value (title, seeds, notes) instead of filling
  a list passed in.

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
