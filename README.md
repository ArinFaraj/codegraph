# codegraph

Exact answers about a Dart or Flutter repository, for coding agents and the
people working next to them: what an edit just broke, where something is
declared, every place it is used and how (`ref.watch`, call, implements,
...), what a change reaches, and renames that are complete or refused with a
reason.

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
codegraph check [files...]          new problems these files cause, in them
                                    and everything that depends on them
codegraph check --all               every problem `dart analyze` reports,
                                    except analyzer plugins
codegraph check --hook              for an agent's after-tool hook (below)
codegraph find <name>               where something is declared
codegraph show <file|dir|symbol>    a file's outline, imports, importers and
                                    provider uses; a directory's pages,
                                    providers with their uses outside it, and
                                    what it reads from elsewhere; or a symbol:
                                    its source, subtypes, overrides, use
                                    counts, and for a provider its readers
codegraph refs <symbol> [-C N]      every use, path:line, grouped by role;
                                    -C N adds N lines of source around each
codegraph rename <symbol> <new>     dry run of a complete rename; --apply
                                    writes it, re-analyzes the affected
                                    files, and rolls back on new errors
codegraph rename <a.dart> <b.dart>  moves a file and rewrites every import,
                                    export and conditional import of it
codegraph doctor [--warm|--stop|--restart]
```

Symbols are written `Name`, `Owner.member`, `path/to/file.dart:name` or
`path/to/file.dart:LINE` (the outermost declaration named on that line). Every verb takes `--json`, `--limit N` (40 rows by
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

A name shared by up to five declarations is answered for each of them by
`show` and `refs`; with more, the candidates are listed (exit 2). `show`
prints a declaration's source up to 60 lines; a longer type shows its members
instead, a longer function its first 60 lines.

In a [slang](https://pub.dev/packages/slang) project generated with
`translation_overrides: true`, `refs` and `show` also take a translation key,
dotted (`home.title`) or as Dart reads it (`t.home.title`). The key is
matched exactly through the generated getter, so the answer is that getter's
uses, preceded by the key's line in each locale file and the locales missing
it:

```text
$ codegraph refs home.unused
translation key home.unused, missing in ar
  en   lib/i18n/yaml/en.yaml:4  Never shown
  ar   missing from lib/i18n/yaml/ar.yaml
refs TranslationsHomeEn.unused (getter, lib/i18n/strings_en.g.dart:24): 0 uses in 0 files
no uses in 17 analyzed files
```

Exit codes: 0 answered, 1 not found, failed, or `check` found problems, 2
ambiguous (candidates listed), 3 rename refused or rolled back, 64 usage, 66
cannot analyze (no `pubspec.yaml`, or no `.dart_tool/package_config.json`:
run `pub get`).

## How it works

- `find` reads a parse-only outline: what each file declares and imports,
  never what a name resolves to. A ready worker answers it from memory;
  without one, the client reads the outline cache in
  `.dart_tool/codegraph/outline.json` (0.1s on a 3,000-file app once
  cached).
- `check`, `refs`, `rename` and `show` go to the worker: one
  background process per checkout that holds the Dart analyzer with its
  search index. Before every answer it checks every analyzed file for
  changes. Its answers cover exactly what `dart analyze` covers, including
  `test/`, `integration_test/`, `tool/` and path packages, and honor
  `analysis_options.yaml` excludes.
- The first answer after the worker starts waits for analysis: about 25
  seconds on a 3,000-file Flutter app with a warm cache, a few minutes the
  first time ever. Progress is printed to stderr. After that, answers take
  milliseconds, and an edit is reflected within a second.
- The worker uses 1.2 to 1.7GB once warm, exits after 20 idle minutes, and at
  most two run at once on a machine (the least recently used one is stopped).
  Running workers are recorded in `~/.cache/codegraph/workers/`, one file per
  checkout.
  Its analyzer cache lives in `~/.cache/codegraph/byte-store/`, one directory
  per checkout, deleted after 30 days unused.

Settings, all optional: `CODEGRAPH_IDLE_MINUTES` (20), `CODEGRAPH_MAX_WORKERS`
(2), `CODEGRAPH_FINE_DEPS=1` (faster updates after API edits, about twice the
memory), `CODEGRAPH_BYTE_STORE` (cache directory).

## Check

`check` answers "what did my edit break" from the warm analyzer, in about a
second where `dart analyze` takes most of a minute on a large app. Its
problems are the ones `dart analyze` prints: analyzer errors, warnings and
lints with each package's own `analysis_options.yaml` applied, TODOs left
out, and the pubspec checks (missing assets and the like). Analyzer plugins
are not run; `check --all` names the ones the workspace enables, so you know
to leave them to `dart analyze`.

The worker keeps a ledger of every file's problems. `check <files>` reports
only problems that are new against it, in those files and in every file that
depends on them, and then records them as seen. Problems in files outside
that reach are left for the change that caused them, so several agents can
share a checkout without being told about each other's half-finished work.
`check` with no files reports everything new anywhere. `check --all` lists
every current problem and is the gate to run before pushing.

`check --hook` is meant to run after every tool call a coding agent makes. It
reads the hook's JSON on stdin. For a tool that writes one file (Edit, Write)
it checks that file; for a shell command it checks every file whose
modification time falls inside the command's run. It prints nothing and
exits 0 unless something new broke, and then it prints the problems on
stderr and exits 2, which Claude Code shows to the agent next to the tool
result. A shell command that wrote nothing costs about 60ms; a check after an
edit takes under a second, after an API change a few seconds. It never waits
for a worker to start: when none is ready, it notes what the call may have
written, starts the worker in the background and returns, and the first call
after warm-up checks those writes too. The worker saves its ledger when it
stops and reloads it on the same commit, so a problem introduced while it
was down is still new to it.

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|Bash",
        "hooks": [{"type": "command", "command": "PATH=\"$HOME/.local/bin:$PATH\"; command -v codegraph >/dev/null || exit 0; cd \"$CLAUDE_PROJECT_DIR\" && exec codegraph check --hook", "timeout": 20}]
      }
    ]
  }
}
```

The command puts `~/.local/bin`, where `install-native` writes the binary,
ahead of the slower pub wrapper, does nothing on a machine without codegraph,
and runs from the project directory, because the hook runs in whatever
directory the session is in. When the Dart package sits below the project
root, `cd` into it instead (`cd "$CLAUDE_PROJECT_DIR/app"`).

Shell commands matter: in the sessions this was built from, most Dart edits
were made by scripts and `sed`, not by the Edit tool.

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
- `UNSUPPORTED`: codegraph does not compute this kind yet (unnamed
  constructors, libraries with parts). Renaming by hand is fine; run
  `dart analyze` afterwards.

Renaming a file (`rename lib/a.dart lib/b/a.dart`) moves it and rewrites
every import, export and conditional import that points at it, keeping
`package:` URIs where the new location allows and recomputing relative ones,
including the moved file's own. The same re-analysis and rollback apply. A
widely imported file makes the analyzer re-resolve its dependents, so the
apply and the next broad query can take tens of seconds on a large app.

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
