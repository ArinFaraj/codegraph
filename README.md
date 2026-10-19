# codegraph

Exact answers about a Dart or Flutter repository, for coding agents and the
people working next to them: where something is declared, every place it is
used and how (`ref.watch`, call, implements, ...), what a change reaches, and
renames that are complete or refused with a reason.

It writes nothing into your repository, needs no CI step, and has nothing to
regenerate. Answers come from the Dart analyzer, kept warm by a background
worker for the checkout you are in, and they reflect the files on disk at the
moment you ask.

## Install

```bash
dart pub global activate -sgit https://github.com/ArinFaraj/codegraph
~/.pub-cache/bin/codegraph install-native   # fast native binary in ~/.local/bin
```

Put `~/.local/bin` before `~/.pub-cache/bin` on `PATH`. Update with the same
two commands. A running worker from an older version is replaced on the next
query.

## Use

```text
codegraph find <name>               where something is declared (instant)
codegraph show <file|dir|symbol>    outline of a file, digest of a directory,
                                    or a symbol: signature, subtypes,
                                    overrides, use counts; providers list
                                    their readers by role
codegraph refs <symbol>             every use, path:line, grouped by role
codegraph impact <symbol|file>      what uses it, one step further, and the
codegraph impact --diff [--base R]  tests that reach it; --diff seeds from
                                    the working tree or the branch since R
codegraph rename <symbol> <new>     dry run of a complete rename; --apply
                                    writes it, re-analyzes the affected
                                    files, and rolls back on new errors
codegraph why <fileA> <fileB>       the import path from one file to another
codegraph doctor [--warm|--stop|--restart]
```

Symbols are written `Name`, `Owner.member`, `path/to/file.dart:name` or
`path/to/file.dart:LINE`. Every verb takes `--json`, `--limit N` (40 rows by
default) and `--all`.

```text
$ codegraph refs sessionProvider
refs sessionProvider (provider, lib/core/session.dart:8): 6 uses in 2 files (1 in tests)
ref.watch (1):
  lib/features/home/home_page.dart:9  final session = ref.watch(sessionProvider);
ref.read (1):
  lib/features/home/home_page.dart:17  deps.ref.read(sessionProvider);
...
```

Exit codes: 0 answered, 1 not found or failed, 2 ambiguous (candidates
listed), 3 rename refused or rolled back, 64 usage, 66 cannot analyze (no
`pubspec.yaml`, or no `.dart_tool/package_config.json`: run `pub get`).

## How it works

- `find`, `show <file>`, `show <dir>` and `why` parse source files. They are
  exact about what a file declares and imports, never about what a name
  resolves to, and they answer in a fraction of a second without the worker.
  Their cache lives in `.dart_tool/codegraph/outline.json`.
- `refs`, `impact`, `rename` and `show <symbol>` go to the worker: one
  background process per checkout that holds the Dart analyzer with its
  search index. Before every answer it checks every analyzed file for
  changes. Its answers cover exactly what `dart analyze` covers, including
  `test/`, `integration_test/`, `tool/` and path packages, and honor
  `analysis_options.yaml` excludes.
- The first answer after the worker starts waits for analysis: about 30
  seconds on a 3,000-file Flutter app with a warm cache, a few minutes the
  first time ever. Progress is printed to stderr. After that, answers take
  milliseconds, and an edit is reflected within a second.
- The worker uses 1.2 to 1.7GB once warm, exits after 20 idle minutes, and at
  most two run at once on a machine (the least recently used one is stopped).
  Its analyzer cache lives in `~/.cache/codegraph/byte-store/`, one directory
  per checkout, deleted after 30 days unused.

Settings, all optional: `CODEGRAPH_IDLE_MINUTES` (20), `CODEGRAPH_MAX_WORKERS`
(2), `CODEGRAPH_FINE_DEPS=1` (faster updates after API edits, about twice the
memory), `CODEGRAPH_BYTE_STORE` (cache directory).

## Rename

A dry run lists every edit. `--apply` stages and installs the edits, then
re-analyzes the edited files and their importers; if any has an error it did
not have before, every file is restored and the errors are printed.

The edit set follows the analyzer's element model: a method's whole override
set (test fakes included), a field together with its getter, setter, `this.x`
and `super.x` parameters and their named arguments, a class together with its
constructors. Refusals come in two kinds:

- `UNSAFE`: the rename could break code codegraph cannot see or fix. Dynamic
  calls to the member name, a member that overrides one declared outside the
  workspace (`build`, `createState`, ...), code generation annotations
  (`@riverpod`, `@freezed`, `@JsonSerializable`, ...), public API of a path
  package whose pubspec does not say `publish_to: none`, a privacy change, or
  a name collision. Stop and decide by hand.
- `UNSUPPORTED`: codegraph does not compute this kind yet (files, unnamed
  constructors). Renaming by hand is fine; run `dart analyze` afterwards.

Dry runs also warn when string literals spell the old name, when an enum
value's name may be stored or sent as data, and when generated files are
edited.

## For agents

[`docs/agents.md`](docs/agents.md) has a short block for `CLAUDE.md` or
`AGENTS.md` and a skill file. Neither is version-stamped, so they never go
stale against the binary.

## Development

```bash
dart pub get
dart analyze --fatal-infos
dart format --set-exit-if-changed .
dart test
dart run tool/lsp_diff.dart <workspace>   # before a release: agree with the language server
```

`lib/src/analysis.dart` is the only file that touches `package:analyzer/src/`;
an analyzer upgrade starts there. The v3 history (plans, benchmarks,
changelog) is in [`archive/v3/`](archive/v3/).

## License

MIT, see [LICENSE](LICENSE).
