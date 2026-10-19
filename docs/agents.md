# codegraph for agents

Two pieces to copy into a repository. Neither carries a version, so they do
not need updating when codegraph is upgraded; `codegraph help` and `--help`
on each verb are the reference.

## Block for CLAUDE.md or AGENTS.md

```markdown
## Navigating the code

Symbols go to `codegraph`, exact strings go to `rg`.

- `codegraph find <name>` / `codegraph show <file|dir|symbol>`: where it is and what it looks like
- `codegraph refs <symbol>`: every use with its line and role (ref.watch, call, implements, ...)
- `codegraph impact <symbol|file>` or `impact --diff`: what a change reaches, and which tests
- `codegraph rename <symbol> <new>` then `--apply`: complete renames, verified by analysis.
  `rename <a.dart> <b.dart>` moves a file and rewrites every import of it.
  `UNSAFE` means stop and report the reason. `UNSUPPORTED` means rename by hand, then run analyze.
```

## Skill (`.claude/skills/code-map/SKILL.md`)

```markdown
---
name: code-map
description: Exact answers about this Dart/Flutter repository - where a class, provider or function is declared, every use of it with its line and role, what a change reaches and which tests cover it, and complete renames. Use before renaming anything, when tracing who watches or reads a provider, who implements a type or overrides a method, or what a change can break. Not for string literals (use rg).
---

# code-map

`codegraph` answers from the Dart analyzer, as the files are on disk now.

| Question | Command |
|---|---|
| Where is X declared? | `codegraph find X` |
| What does this file contain and who imports it? | `codegraph show path/to/file.dart` |
| What is in this feature directory? | `codegraph show lib/features/payment` |
| Signature, subtypes, overrides, use counts of X | `codegraph show X` |
| Every use of X with its line | `codegraph refs X` |
| What breaks if X or this file changes, which tests reach it | `codegraph impact X` |
| What does my uncommitted change reach | `codegraph impact --diff` (`--base dev` for the branch) |
| Rename X everywhere | `codegraph rename X newName`, read the edits, then add `--apply` |
| Move a file and fix every import | `codegraph rename lib/a.dart lib/b/a.dart`, then `--apply` |
| How does file A end up depending on B | `codegraph why A B` |

Name a symbol as `Name`, `Owner.member`, `path.dart:name` or `path.dart:LINE`.
Exit code 2 lists the candidates when a name is ambiguous; pick one and rerun.

Rename refusals:
- `UNSAFE: ...` the rename could break code codegraph cannot see (dynamic
  calls, framework overrides, code generation, a publishable package). Do not
  work around it; report the reason.
- `UNSUPPORTED: ...` a kind codegraph cannot compute yet. Rename by hand and
  run `dart analyze`.
- `rolled back:` the applied rename produced errors and every file was
  restored; the errors are listed.

Limits: string literals are not symbols; `impact` lists tests that reference
the change within two steps, not a guaranteed test plan; dynamic dispatch is
visible only as a rename refusal. The first `refs`/`impact`/`rename`/`show
<symbol>` in a session can wait for the analyzer (progress on stderr);
`codegraph doctor` shows the worker's state.
```

## Session hook (optional)

Starting the worker when a session starts hides the analyzer warm-up. It
prints nothing and costs no tokens:

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "codegraph doctor --warm >/dev/null 2>&1 &"}]}
    ]
  }
}
```
