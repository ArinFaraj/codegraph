// `codegraph init [--ci]` - install the agent trigger layer into a host project.
//
// The graph only gets used if agents are TOLD about it in always-loaded
// context (a root CLAUDE.md block), reminded deterministically (SessionStart
// hook), and given a skill whose description matches real prompts. This
// command stamps all three, idempotently:
//
//   CLAUDE.md                             marker block appended (or file created)
//   .claude/hooks/code-graph-refresh.sh   fail-safe check-then-regen at session start
//   .claude/settings.json                 hook wiring (created only if missing)
//   .claude/skills/code-map/SKILL.md      prompt-shaped skill
//   docs/maps/LIMITATIONS.md              seed for the self-improving loop
//   .github/workflows/code-graph.yml      freshness CI gate (--ci only)
//   .cursor/rules/codegraph.mdc           same command block, for Cursor
//                                          (if .cursor/ exists or --cursor passed)
import 'dart:io';

import 'cli_util.dart' show runGit;

void init(List<String> args,
    {required String version, required String repoUrl}) {
  if (!File('pubspec.yaml').existsSync()) {
    stderr.writeln('run from the package root of a Dart/Flutter project');
    exit(66);
  }
  final ci = args.contains('--ci');

  _write('.claude/hooks/code-graph-refresh.sh', _hook(repoUrl, version),
      executable: true);
  _write('.claude/skills/code-map/SKILL.md', _skill(repoUrl, version));
  _write('docs/maps/LIMITATIONS.md', _limitations(repoUrl), upgradeable: false);
  if (ci)
    _write('.github/workflows/code-graph.yml', _workflow(repoUrl, version));

  _appendClaudeBlock(repoUrl, version);
  if (Directory('.cursor').existsSync() || args.contains('--cursor')) {
    _write('.cursor/rules/codegraph.mdc', _cursorRule(repoUrl, version));
  }
  _wireSettings();
  _gitignoreGraphJson();
  _migrationHint();
  _monorepoGuidance();
  _lintConfigHint();

  stdout.writeln('''

Done. Next steps:
  1. ~/.pub-cache/bin/codegraph install-native # remove pub launcher overhead
  2. codegraph build --syntax # generate fast navigation maps for this project
  3. codegraph daemon         # optional single workspace graph worker
  4. codegraph doctor         # verify the install
  5. commit CLAUDE.md, .claude/, docs/maps/*.md (NOT generated JSON indexes)
Re-running init on an existing install? Scaffolding already here is skipped -
run `codegraph upgrade` to refresh it to this version instead.
Engine wrong or missing a relation? Fix it at $repoUrl, changelog it there,
then update everywhere: dart pub global activate -sgit $repoUrl --git-ref v$version''');
}

/// Whole-line begin marker of a REAL generated block: `<!-- codegraph:begin -->`
/// or `<!-- codegraph:begin vX -->`, alone on its line. Anchored so prose that
/// merely mentions the marker (inside a code fence, or mid-sentence) is NOT
/// mistaken for an installed block. Group 2 captures the version, when present.
final _claudeBeginLine =
    RegExp(r'^<!-- codegraph:begin( v(\S+))? -->$', multiLine: true);

/// Whole-line end marker of a real generated block.
final _claudeEndLine = RegExp(r'^<!-- codegraph:end -->$', multiLine: true);

/// True when [claudeMdText] contains a REAL generated begin marker (alone on
/// its line). Shared by doctor + passport so prose that merely mentions the
/// marker isn't reported as an installed block.
bool hasClaudeBeginLine(String claudeMdText) =>
    _claudeBeginLine.hasMatch(claudeMdText);

/// Reads the version stamped into the installed scaffolding, or null when no
/// stamp is found. Prefers the CLAUDE.md marker (`<!-- codegraph:begin vX -->`,
/// matched only when it is alone on its line - a real block always is),
/// falls back to the hook's `# codegraph-scaffold: vX` line. Never guesses: an
/// unparseable/absent stamp returns null so callers nudge to upgrade.
String? scaffoldVersion() {
  final claude = File('CLAUDE.md');
  if (claude.existsSync()) {
    final m = _claudeBeginLine.firstMatch(claude.readAsStringSync());
    if (m != null && m.group(2) != null) return m.group(2);
  }
  final hook = File('.claude/hooks/code-graph-refresh.sh');
  if (hook.existsSync()) {
    final m = RegExp(r'codegraph-scaffold: v(\S+)')
        .firstMatch(hook.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

/// `codegraph upgrade` - refresh codegraph-OWNED scaffolding to this binary's
/// version WITHOUT clobbering any host-owned content. Overwrites the hook and
/// skill in place; overwrites the cursor rule and CI workflow only if they
/// already exist (creating them is an init/opt-in decision); replaces the
/// CLAUDE.md block strictly between its markers, preserving every byte outside.
/// Never touches settings.json, LIMITATIONS.md, codegraph.json, notes/, or the
/// graph. Idempotent: a second run over identical bytes reports no changes.
int upgrade(List<String> args,
    {required String version, required String repoUrl}) {
  if (!File('pubspec.yaml').existsSync()) {
    stderr.writeln('run from the package root of a Dart/Flutter project');
    return 66;
  }

  final hasHook = File('.claude/hooks/code-graph-refresh.sh').existsSync();
  final hasClaudeBlock = File('CLAUDE.md').existsSync() &&
      _claudeBeginLine.hasMatch(File('CLAUDE.md').readAsStringSync());
  if (!hasHook && !hasClaudeBlock) {
    stderr.writeln(
        'no codegraph scaffolding found here - run `codegraph init` first');
    return 66;
  }

  _refresh('.claude/hooks/code-graph-refresh.sh', _hook(repoUrl, version),
      executable: true);
  _refresh('.claude/skills/code-map/SKILL.md', _skill(repoUrl, version));
  _refresh('.cursor/rules/codegraph.mdc', _cursorRule(repoUrl, version),
      onlyIfExists: true);
  _refresh('.github/workflows/code-graph.yml', _workflow(repoUrl, version),
      onlyIfExists: true);
  _upgradeClaudeBlock(repoUrl, version);

  stdout.writeln(
      '\nrun: codegraph build --syntax   # regenerate fast maps if stale');
  stdout.writeln(
      'review docs/maps/LIMITATIONS.md - merge any new known gaps from the release notes (upgrade never overwrites this file)');
  return 0;
}

/// Overwrite a codegraph-owned file with fresh content. [onlyIfExists] skips
/// files not already present (upgrade must not newly create opt-in artifacts).
/// Reports "unchanged" when the bytes already match (idempotent re-run).
void _refresh(String path, String content,
    {bool executable = false, bool onlyIfExists = false}) {
  final f = File(path);
  if (!f.existsSync()) {
    if (onlyIfExists) return;
  } else if (f.readAsStringSync() == content) {
    stdout.writeln('unchanged  $path');
    return;
  }
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  if (executable && !Platform.isWindows) {
    Process.runSync('chmod', ['+x', path]);
  }
  stdout.writeln('refreshed  $path');
}

/// Replace the CLAUDE.md block between the WHOLE-LINE `<!-- codegraph:begin -->`
/// and `<!-- codegraph:end -->` markers (inclusive), preserving all bytes
/// outside that range. Anchoring to whole lines means prose that merely
/// documents the markers (in a code fence / mid-sentence) is left untouched. No
/// whole-line marker pair -> note + skip (appending is init's job).
void _upgradeClaudeBlock(String repoUrl, String version) {
  final f = File('CLAUDE.md');
  if (!f.existsSync()) {
    stdout.writeln('note  CLAUDE.md absent - run `codegraph init` to add the '
        'codegraph block');
    return;
  }
  final text = f.readAsStringSync();
  // Anchor to WHOLE-LINE markers so a CLAUDE.md that merely documents the
  // markers (inside a code fence / prose) is never mistaken for a real block
  // and rewritten. A real generated block always has both markers on their own
  // line.
  final beginMatch = _claudeBeginLine.firstMatch(text);
  final endMatch = beginMatch == null
      ? null
      : _claudeEndLine.firstMatch(text.substring(beginMatch.start));
  if (beginMatch == null || endMatch == null) {
    stdout.writeln('note  CLAUDE.md has no codegraph block - run `codegraph '
        'init` to add one');
    return;
  }
  final endEnd = beginMatch.start + endMatch.end;
  final block = '''
${_claudeBegin(version)}
${_commandBlock(repoUrl)}
<!-- codegraph:end -->''';
  final updated =
      text.substring(0, beginMatch.start) + block + text.substring(endEnd);
  if (updated == text) {
    stdout.writeln('unchanged  CLAUDE.md (codegraph block)');
    return;
  }
  f.writeAsStringSync(updated);
  stdout.writeln('refreshed  CLAUDE.md (codegraph block)');
}

/// If no `codegraph.json` exists and this looks like a Riverpod+GoRouter app
/// (`lib/features/` present), suggest a starter config - guidance only, never
/// written (the host authors its own rules).
void _lintConfigHint() {
  if (File('codegraph.json').existsSync()) return;
  if (!Directory('lib/features').existsSync()) return;
  stdout.writeln('''

NOTE  no codegraph.json - starter for a Riverpod+GoRouter app:
  {
    "features": ["lib/features/"],
    "banned_provider_kinds": ["StateProvider", "StateNotifierProvider", "ChangeNotifierProvider"]
  }
  then: codegraph lint --write-baseline''');
}

const _graphJsonEntry = 'docs/maps/code_graph.json';
const _refactorIndexEntry = 'docs/maps/refactor_index.json';
const _generatedJsonEntries = [_graphJsonEntry, _refactorIndexEntry];

/// Appends the generated-graph JSON to `.gitignore` (creating the file if
/// missing). Idempotent - skips if the line is already present anywhere in
/// the file.
void _gitignoreGraphJson() {
  final f = File('.gitignore');
  var existing = f.existsSync() ? f.readAsStringSync() : '';
  final lines = existing.split('\n').map((line) => line.trim()).toSet();
  final missing =
      _generatedJsonEntries.where((entry) => !lines.contains(entry));
  if (missing.isEmpty) {
    stdout.writeln('skip  .gitignore (generated indexes already present)');
    return;
  }
  for (final entry in missing) {
    final sep = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    existing = '$existing$sep$entry\n';
    stdout.writeln('wrote .gitignore ($entry)');
  }
  f.writeAsStringSync(existing);
}

/// If `docs/maps/code_graph.json` is already tracked by git (from before it
/// was gitignored), print a one-time migration hint. Never fails init if git
/// is unavailable or the file simply isn't tracked.
void _migrationHint() {
  final result = runGit(['ls-files', '--error-unmatch', _graphJsonEntry]);
  if (result == null) return;
  if (result.exitCode == 0) {
    stdout.writeln(
      'NOTE  $_graphJsonEntry is tracked by git - untrack it: '
      'git rm --cached $_graphJsonEntry && git commit',
    );
  }
}

/// If the package root (cwd) is not the git root, print a one-time note:
/// `.claude/settings.json` (and the hook) belong at the git root in a
/// monorepo, and the generated hook self-locates the package from there.
/// Never fails init if git is unavailable or this isn't a git repo.
void _monorepoGuidance() {
  final result = runGit(['rev-parse', '--show-toplevel']);
  if (result == null) return;
  if (result.exitCode != 0) return;
  final gitRoot = (result.stdout as String).trim();
  final pkgRoot = Directory.current.resolveSymbolicLinksSync();
  if (gitRoot == pkgRoot) return;
  stdout.writeln(
    'NOTE  package root ($pkgRoot) is not the git root ($gitRoot) - in a '
    'monorepo, .claude/settings.json (and the hook) should live at the git '
    'root; the generated hook self-locates this package from there.',
  );
}

/// [upgradeable] distinguishes codegraph-owned scaffolding (hook, skill,
/// cursor rule, workflow) - stale ones should go through `codegraph upgrade`,
/// which refreshes in place without disturbing anything else - from
/// host-owned files like LIMITATIONS.md, which accumulate a hand-written log
/// and must never be suggested for deletion.
void _write(String path, String content,
    {bool executable = false, bool upgradeable = true}) {
  final f = File(path);
  if (f.existsSync()) {
    stdout.writeln(upgradeable
        ? 'skip  $path (exists - run `codegraph upgrade` to refresh it to this version)'
        : 'skip  $path (exists - host-owned, codegraph never overwrites it)');
    return;
  }
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  if (executable && !Platform.isWindows) {
    Process.runSync('chmod', ['+x', path]);
  }
  stdout.writeln('wrote $path');
}

/// Shared doctrine for every agent-facing template: never embed host-specific
/// product, vendor SDK, or private-project names in committed guidance.
const _docsHygieneRule = '''
**Docs hygiene:** LIMITATIONS.md entries, area notes (`docs/maps/notes/`), and
any other committed agent guidance must use generic descriptions only - never
name a specific product, vendor SDK, or private project.''';

/// Shared body for both the CLAUDE.md block and the Cursor `.mdc` rule: the
/// brief-first command list + guidance paragraph. One copy so the two
/// templates cannot drift.
String _commandBlock(String repoUrl) => '''
**This repo has a resolved code graph and an edit actuator. Two rules: (1) NAVIGATE with one subsecond native `codegraph` query instead of grepping; (2) before renaming ANY symbol (method, function, class, enum, mixin), run `codegraph rename` as a dry run and follow it - if it REFUSES, do not do the rename by hand; the refusal reason is the answer.**

Navigate (covers `lib/` + `packages/`; read what it points at before relying on a load-bearing claim):

```bash
codegraph brief <thing>        # one-shot context card - a provider, file, area, or symbol
codegraph uses <thing>         # who uses X - readers, call sites, subtypes, importers
codegraph change <thing>       # pre-change pack: dependents + subtype tree + untested in blast radius
codegraph find <NameOrFile>    # where is X - ranked by in-degree
codegraph sym <Symbol>         # symbol card: signature, doc, members, imported-by
codegraph skeleton <file>      # per-file outline with line numbers (instead of reading the file)
codegraph readers <provider>   # who watches/reads/listens it ([unconfirmed] = name-matched only)
codegraph callers <Symbol> [--resolved]  # call sites; --resolved attributes same-named methods
                               #   to their REAL target + shows the override chain (slow, exact)
codegraph callchain <Symbol>   # static call tree + control-flow hazard flags
codegraph wiring <file>        # a file's full wiring, both directions
codegraph impls <Type>         # implementers/subtypes (transitive, incl. test fakes)
codegraph path <A> <B>         # how two files connect
codegraph route <RouteData>    # typed-route card: placement, page, redirects, callers
codegraph impact <thing>       # transitive dependents (what breaks if this changes)
codegraph review [--base main] # branch blast radius + changed-but-untested + lint
codegraph affected-tests       # targeted test plan; uncertainty expands to full suites
codegraph lint                 # architecture rules - run before committing
```

Change safely (the actuator - element-precise, complete-or-refuses):

```bash
codegraph rename <Class.method|function> <newName>   # dry run: every real reference,
                                                     #   whole override sets move together
codegraph rename <target> <newName> --apply          # write it (staged, rollback-backed)
```

Covers methods, functions, classes, enums, and mixins - a class rename moves
every constructor, type annotation, is/as check, type argument, tear-off, and
static access together. A rename REFUSES when it cannot be proven complete and
safe: ambiguous bare names (qualify as `Class.member` or
`path/to/file.dart:name`), framework overrides,
public API of packages listed in `codegraph.json` `publishedPackages`,
unresolved/dynamic uses. Treat a refusal as the correct answer and report it -
never route around it by editing manually.

Feature overview in one read: `docs/maps/<area>.md` (index: `docs/maps/INDEX.md`). Graph stale after your edits? `codegraph build --syntax` for fast navigation; use `codegraph build --resolved` only before element-precise route/refactor work. After `codegraph upgrade` or a CLI update: review `docs/maps/LIMITATIONS.md` and merge any new known gaps from the release notes (upgrade never overwrites that file). Engine wrong/incomplete? Fix it at the source repo ($repoUrl), changelog it there, re-activate, and log the gap in `docs/maps/LIMITATIONS.md` (generic wording only - see docs hygiene below). Learned something non-obvious about an area? Append it to `docs/maps/notes/<area>.md` - brief surfaces it automatically.

$_docsHygieneRule''';

/// The CLAUDE.md block's opening marker, carrying the version stamp:
/// `<!-- codegraph:begin v0.8.0 -->`. Presence is detected by the WHOLE-LINE
/// [_claudeBeginLine] anchor (version optional) so a block written by any
/// version still counts, while prose mentioning the marker does not.
const claudeMarkerPrefix = '<!-- codegraph:begin';
String _claudeBegin(String version) => '$claudeMarkerPrefix v$version -->';

/// Machine-readable stamp line embedded in each generated non-CLAUDE artifact
/// (hook, skill, cursor rule, workflow). `scaffoldVersion()` reads it back.
String _scaffoldStamp(String version) => 'codegraph-scaffold: v$version';

void _appendClaudeBlock(String repoUrl, String version) {
  final f = File('CLAUDE.md');
  final existing = f.existsSync() ? f.readAsStringSync() : '';
  if (_claudeBeginLine.hasMatch(existing)) {
    stdout.writeln('skip  CLAUDE.md (codegraph block already present)');
    return;
  }
  final block = '''
${_claudeBegin(version)}
${_commandBlock(repoUrl)}
<!-- codegraph:end -->
''';
  f.writeAsStringSync(
    existing.isEmpty ? '# ${_projectName()}\n\n$block' : '$existing\n$block',
  );
  stdout.writeln(
    existing.isEmpty
        ? 'wrote CLAUDE.md'
        : 'appended codegraph block to CLAUDE.md',
  );
}

String _cursorRule(String repoUrl, String version) => '''
---
description: Query the code graph before grepping
alwaysApply: true
---
# ${_scaffoldStamp(version)}

${_commandBlock(repoUrl)}
''';

String _projectName() =>
    RegExp(r'^name:\s*(\S+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())
        ?.group(1) ??
    'project';

void _wireSettings() {
  // Quotes around the path must be JSON-escaped (\") - this string is spliced
  // into a JSON template below, not a shell script. An unescaped `"` here
  // produces invalid settings.json every time (caught 2026-07-02).
  const cmd =
      'bash \\"\$CLAUDE_PROJECT_DIR/.claude/hooks/code-graph-refresh.sh\\"';
  final f = File('.claude/settings.json');
  if (!f.existsSync()) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('''
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$cmd"
          }
        ]
      }
    ]
  }
}
''');
    stdout.writeln('wrote .claude/settings.json');
    return;
  }
  if (f.readAsStringSync().contains('code-graph-refresh.sh')) {
    stdout.writeln('skip  .claude/settings.json (hook already wired)');
    return;
  }
  // Don't rewrite a settings file we don't own - tell the operator what to add.
  stdout.writeln('''
NOTE  .claude/settings.json exists - add this to its "hooks"."SessionStart":
      { "hooks": [ { "type": "command", "command": "$cmd" } ] }''');
}

String _hook(String repoUrl, String version) => '''
#!/bin/bash
# ${_scaffoldStamp(version)}
# SessionStart: keep docs/maps/code_graph.json fresh so agents can trust it.
# Fail-safe by design: every path exits 0 - a broken toolchain must never block a session.
# REJECTED: per-edit (PostToolUse) regen - seconds of latency on every edit. Do NOT re-propose.
# Installed by `codegraph init` ($repoUrl).
cd "\${CLAUDE_PROJECT_DIR:-\$(dirname "\$0")/../..}" 2>/dev/null || exit 0
# Monorepo: settings/hook live at the git root, but the package (pubspec.yaml)
# may be one level down. If there's no pubspec.yaml here, probe immediate
# subdirs for one containing both pubspec.yaml and docs/maps/, and cd into
# the first match by sorted name. No match -> exit 0 silently (fail-safe).
if [ ! -f pubspec.yaml ]; then
  pkg=""
  for d in */; do
    if [ -f "\$d/pubspec.yaml" ] && [ -d "\$d/docs/maps" ]; then
      pkg="\$d"
      break
    fi
  done
  [ -n "\$pkg" ] && cd "\$pkg" 2>/dev/null || exit 0
fi
GRAPH=docs/maps/code_graph.json
if [ -x "\$HOME/.local/bin/codegraph" ]; then
  CG="\$HOME/.local/bin/codegraph"
else
  CG="\$(command -v codegraph || echo "\$HOME/.pub-cache/bin/codegraph")"
fi
if [ ! -x "\$CG" ]; then
  echo "codegraph not installed - dart pub global activate -sgit $repoUrl --git-ref v$version"
  exit 0
fi

stale=""
if [ ! -f "\$GRAPH" ]; then
  stale=yes
elif [ -n "\$(find lib packages/*/lib -name '*.dart' -newer "\$GRAPH" -print -quit 2>/dev/null)" ]; then
  stale=yes
fi

if [ -n "\$stale" ]; then
  "\$CG" build --syntax >/dev/null 2>&1 \\
    || { echo "code graph: STALE (regen failed - run: codegraph build --syntax)"; exit 0; }
fi

"\$CG" passport 2>/dev/null || echo "code graph fresh (\$GRAPH)."
echo "relationship questions -> codegraph brief|find|sym|skeleton|wiring|readers (see CLAUDE.md)"
# Keep one event-driven syntax-graph worker available between commands. Its
# workspace reservation is exclusive, so concurrent hooks never duplicate it.
nohup "\$CG" daemon >/dev/null 2>&1 &
exit 0
''';

String _skill(String repoUrl, String version) => '''
---
name: code-map
description: Query this repo's resolved code graph AND change code through its actuator. One subsecond native command answers "where is X", "what uses/watches provider X", "what depends on this file", "who implements this type", "who calls this exact method", "what breaks if I change this", "which tests must run". Renaming anything (method, function, class, enum, mixin)? Use `codegraph rename` FIRST - it edits every real reference or refuses when unsafe. Use at the start of ANY code task here: fixing a bug, investigating behavior, tracing a flow, refactoring, renaming, checking whether a change is safe, planning or reviewing a feature, or finding the file/provider/class/screen for something. Covers lib/ AND packages/*/lib. Reach for it before Grep/Glob/broad file reads and BEFORE hand-editing a rename.
---
<!-- ${_scaffoldStamp(version)} -->

# Code map - query the graph first, change through the actuator

This repo ships a resolved code graph (built by the real Dart analyzer via the
`codegraph` CLI), per-area maps, and an edit actuator. Use the graph to answer
relationship questions cheaply instead of grepping; use the actuator to make
element-precise edits that refuse when unsafe. Resolved analysis is the
default: edges backed by element identity are exact; reader edges marked
`[unconfirmed]` are name-matched only - read the file before relying on one.

## First move on any feature

Read the area's map - a summary, not the full wiring:

- Index of areas: `docs/maps/INDEX.md`
- An area: `docs/maps/<area>.md` - counts, providers ranked by reader count,
  entry pages, and cross-area providers consumed. For the full wiring (the
  watch/read/listen table, navigation targets, file inventory), run
  `codegraph brief <area>` instead of reading the file.

## Targeted questions - use the query CLI

```
codegraph brief   <thing>          # one-shot context card: provider, file, area, or symbol
codegraph find    <substring>      # locate a file, provider, or symbol (class/enum/function)
codegraph sym     <SymbolName>     # symbol card: signature, doc, members, imported-by
codegraph skeleton <file>          # per-file outline with line numbers (instead of reading)
codegraph readers <providerName>   # who watches/reads/listens it (+ where declared)
codegraph callers <Symbol>         # every call site (file:line) of a method - incl. tests
codegraph callchain <Symbol>       # static call tree + control-flow hazard flags
codegraph wiring  <fileSubstring>  # a file's full wiring, both directions
codegraph impls   <TypeName>       # who implements/extends a type (incl. test fakes)
codegraph path    <A> <B>          # how two files connect
codegraph impact  <thing>          # transitive dependents (what breaks if this changes)
codegraph diff    [--base main]    # branch blast-radius card
codegraph affected-tests [--base main] # explain targeted/full test commands
codegraph unused  [providers|files] # dead-code candidates
codegraph untested                 # coverage gaps (zero test references)
```

Start with `brief`; fall back to targeted verbs. Add `--budget N` to cap output. The graph spans `lib/` **and** `packages/*/lib`,
so `find <WidgetClass>` answers with the definition site. The full
machine-readable graph is `docs/maps/code_graph.json`.

Coverage gaps: `codegraph untested` lists providers/files with zero test references (ranked by in-degree).

Learned something non-obvious about an area? Append it to `docs/maps/notes/<area>.md` - brief surfaces it automatically.

## Changing code - the actuator rule

Before renaming ANY symbol (method, function, class, enum, or mixin), run the actuator as a dry run:

```
codegraph rename <Class.method|function> <newName>          # dry run
codegraph rename <Class.method|function> <newName> --apply  # write it
```

It covers methods, functions, classes, enums, and mixins, and edits every
real (element-resolved) reference - whole override sets move together, test
fakes included; a class rename carries constructors, type annotations, is/as
checks, type arguments, tear-offs, and static access. Or it REFUSES with a
reason: ambiguous bare name (qualify as `Class.member` or
`path/to/file.dart:name`), framework override,
public API of a package listed in `codegraph.json` `publishedPackages`, or
unresolved/dynamic uses. A refusal IS the answer: report it; never do the
same rename by hand around it. For exact per-target call sites before a
signature change, `codegraph callers <Symbol> --resolved` attributes each site
to its real declaring class and prints the override chain.

## When to use which

- "Rename X (any symbol)" -> `rename X newName` (dry run), then `--apply`.
- "Is it safe to change this method?" -> `callers X --resolved` + `change X`.
- "What does this feature do / how is it wired?" -> read `docs/maps/<area>.md`.
- "If I change provider X, what breaks?" -> `readers X`.
- "Which tests should this branch run?" -> `affected-tests --base main`;
  targeted plans remain advisory until the mutation oracle unlocks skipping.
- "What does file Y depend on / who depends on it?" -> `wiring Y`.
- "What are the implementations of interface Z?" -> `impls Z`.
- "Where is thing T?" -> `find T`.
- "What's dead / unused?" -> `unused providers|files` - then **confirm** with an
  exact-path grep across ALL Dart roots (`lib test integration_test`) and a
  whole-project analyze before deleting. The graph is the candidate generator,
  not the delete list.

## Graph vs grep - the rule

Query the **graph** for *relationships*; use **grep/file-reading** for *exact
text*, implementation syntax, and always before editing. Known caveats:
`docs/maps/LIMITATIONS.md`. For completeness-critical work (deletions, broad
renames) cross-check the graph's answer with grep.

## Keep it fresh

A SessionStart hook (`.claude/hooks/code-graph-refresh.sh`) auto-regenerates
the graph when stale and starts one event-driven workspace worker. Check it
with `codegraph daemon status`; stop it with `codegraph daemon stop`. The
worker refreshes only the untracked syntax graph and never rewrites committed
Markdown maps. Use `codegraph build --resolved` when an element-precise
route/refactor needs it.

## After upgrading the CLI

When `codegraph upgrade` or `dart pub global activate` brings a newer binary:

1. Run `codegraph build --syntax` to regenerate the fast graph.
2. Run `~/.pub-cache/bin/codegraph install-native` to replace the fast binary.
3. Review `docs/maps/LIMITATIONS.md` - merge any new known gaps from the engine
   release notes. Upgrade refreshes the skill and hook but never overwrites
   LIMITATIONS.md (it is host-owned).

$_docsHygieneRule

## Improving the engine (the self-correcting loop)

The engine lives in its own repo: $repoUrl - NOT in this project. If a query
returns something wrong or incomplete:

1. Reproduce the bad query here; note it in `docs/maps/LIMITATIONS.md` (dated,
   generic wording - no product or vendor SDK names).
2. Fix the engine in a clone of $repoUrl (`lib/src/engine.dart` extraction,
   `lib/src/query.dart` queries), add a CHANGELOG.md line, commit/tag.
3. Update the source package: `dart pub global activate -sgit $repoUrl --git-ref v$version`
4. Install its native executable: `~/.pub-cache/bin/codegraph install-native`
5. `codegraph build --syntax` here to regenerate with the fix.

If instead you learn a reusable *codebase* pattern (not an engine bug), capture
it as a skill or memory so future sessions inherit it.
''';

String _limitations(String repoUrl) => '''
# Code graph - known limitations & the feedback loop

Generated by the `codegraph` CLI ($repoUrl). The engine parses with the real
Dart analyzer but uses pragmatic resolution:

- **Provider usage is file-level**, matched by name against a global registry.
  Duplicate names are resolved per-reader by import reachability; unresolvable
  ties are flagged `ambiguous`, never guessed.
- **Navigation targets are captured as expressions** (e.g. `AppPaths.x.path`),
  not resolved to route definitions.
- **The graph is lib/ + packages/*/lib only** - so `unused` output is a
  CANDIDATE list: confirm with exact-path grep across all Dart roots +
  whole-project analyze before deleting. (`callers` and `impls` do scan the test
  roots on demand, so a method's call sites and an interface's test fakes are
  covered without a separate grep.)
- **Syntax fallback recognizes common Ref receiver names**. Resolved builds use
  the receiver's Ref/WidgetRef/ProviderContainer type and also model
  watch/read/listen/invalidate/refresh, including wrapper-held refs.
- **`callers` tracks method/function calls only** - field/member *access*
  (e.g. `state.sessionToken`) is not indexed; use `find <field>` for lifecycle
  helpers or read the declaring class.
- **`impact` resolves providers and files, not methods** - for a method
  signature change, use `callers <method>` + `impls <Interface>` instead.
- **ProviderScope overrides are not modeled** - readers/wiring tell you who
  SUBSCRIBES to a provider, not which implementation RUNS in a given scope
  (bootstrap/test/route overrides can swap it).
- **Syntax `callers` merges same-named declarations**. Pass `--resolved` for
  element-precise target attribution; a current resolved build serves that
  answer from its semantic index. Family providers still collapse to one node
  (every instance is the same provider interaction edge).
- **OpenAPI / generated model changes** (field removals on DTOs) are outside
  the graph - `find` locates the class but not what changed; use `git diff` on
  the API package or the regen report.
- **Committed agent docs stay generic** - LIMITATIONS.md entries and area notes
  must not name a specific product, vendor SDK, or private project.

**When the graph is wrong here:** add a dated line below describing the gap
(generic wording only),
then fix the ENGINE at $repoUrl (changelog it there), re-activate the CLI, and
`codegraph build`. Don't work around a wrong graph silently.

## Log
''';

String _workflow(String repoUrl, String version) => '''
# ${_scaffoldStamp(version)}
name: Code graph

on:
  pull_request:
    paths:
      - 'lib/**'
      - 'packages/*/lib/**'
      - '.github/workflows/code-graph.yml'
  push:
    branches: [main]
    paths:
      - 'lib/**'
      - 'packages/*/lib/**'
      - '.github/workflows/code-graph.yml'

permissions:
  contents: read
  pull-requests: write

jobs:
  code-graph:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: dart-lang/setup-dart@v1
      # codegraph parses syntax only - the host project needs NO pub get.
      - run: dart pub global activate -sgit $repoUrl --git-ref v$version
      - name: Check AI navigation maps are fresh
        run: dart pub global run codegraph:codegraph check
      # Fails on NEW architecture violations. First run: author codegraph.json, then
      # 'codegraph lint --write-baseline' and commit docs/maps/lint-baseline.json.
      - name: Check architecture rules
        run: dart pub global run codegraph:codegraph lint
      - name: Post codegraph diff card
        if: github.event_name == 'pull_request'
        env:
          GH_TOKEN: \${{ github.token }}
          PR_NUMBER: \${{ github.event.number }}
        run: |
          git fetch origin "\$GITHUB_BASE_REF" --depth=200 || true
          {
            echo '## codegraph diff'
            echo '```'
            dart pub global run codegraph:codegraph diff --base "origin/\$GITHUB_BASE_REF" || echo '(diff unavailable)'
            echo '```'
          } > cg-diff.md
          gh pr comment "\$PR_NUMBER" --body-file cg-diff.md --edit-last \\
            || gh pr comment "\$PR_NUMBER" --body-file cg-diff.md
''';
