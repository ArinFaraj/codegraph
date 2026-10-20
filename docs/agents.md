# codegraph for agents

Two pieces to copy into a repository. Neither carries a version, so they do
not need updating when codegraph is upgraded; `codegraph help` and `--help`
on each verb are the reference.

## Block for CLAUDE.md or AGENTS.md

```markdown
## Navigating the code

Problems your edits cause are reported after each tool call. Before pushing,
run `codegraph check --all`. Symbols go to `codegraph`, exact strings go to
`rg`.

- `codegraph find <name>` / `codegraph show <file|dir|symbol>`: where it is, and its source
- `codegraph refs <symbol>`: every use with its line and role (ref.watch, call, implements, ...)
- `codegraph rename <symbol> <new>` then `--apply`: complete renames, verified by analysis.
  `rename <a.dart> <b.dart>` moves a file and rewrites every import of it.
  `UNSAFE` means stop and report the reason. `UNSUPPORTED` means rename by hand, then run analyze.
```

## Skill (`.claude/skills/code-map/SKILL.md`)

```markdown
---
name: code-map
description: Exact answers about this Dart/Flutter repository - what an edit broke, where a class, provider or function is declared and what its source is, every use of it with its line and role, complete renames and file moves. Use before renaming anything, when tracing who watches or reads a provider, who implements a type or overrides a method, or what a change broke. Not for string literals (use rg).
---

# code-map

`codegraph` answers from the Dart analyzer, as the files are on disk now.

| Question | Command |
|---|---|
| What did my edits break? | Reported after each tool call by the hook; `codegraph check` for everything new, `codegraph check --all` before pushing |
| Where is X declared? | `codegraph find X` |
| What is X: its source, subtypes, overrides, readers | `codegraph show X` |
| What does this file contain and who imports it? | `codegraph show path/to/file.dart` |
| What is in this feature directory? | `codegraph show lib/features/payment` |
| Every use of X with its line | `codegraph refs X` (`-C 3` for source around each) |
| Rename X everywhere | `codegraph rename X newName`, read the edits, then add `--apply` |
| Move a file and fix every import | `codegraph rename lib/a.dart lib/b/a.dart`, then `--apply` |

Name a symbol as `Name`, `Owner.member`, `path.dart:name` or `path.dart:LINE`.
A name shared by up to five declarations is answered for each; with more,
exit code 2 lists the candidates, so pick one and rerun.

Rename refusals:
- `UNSAFE: ...` the rename could break code codegraph cannot see (dynamic
  calls, framework overrides, code generation, a publishable package). Do not
  work around it; report the reason.
- `UNSUPPORTED: ...` a kind codegraph cannot compute yet. Rename by hand and
  run `codegraph check`.
- `rolled back:` the applied rename produced errors and every file was
  restored; the errors are listed.

Limits: string literals are not symbols; dynamic dispatch is visible only as
a rename refusal; `check` does not run analyzer plugins (riverpod_lint), CI
does. Which tests a change reaches: `dart run tools/test_changed.dart --list`.
`codegraph doctor` shows the worker's state.
```

## Hooks

The first starts the worker when a session starts, which hides the analyzer
warm-up. The second reports what each tool call broke. Both print nothing
when there is nothing to say:

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "codegraph doctor --warm >/dev/null 2>&1 &"}]}
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|Bash",
        "hooks": [{"type": "command", "command": "codegraph check --hook", "timeout": 20}]
      }
    ]
  }
}
```
