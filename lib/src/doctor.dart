// `codegraph doctor` — read-only install health check. Answers "is the
// scaffolding actually wired" (hook executable + registered, gitignore,
// CLAUDE.md marker, CI gate, graph/binary format skew) so a broken install
// fails loudly instead of silently producing stale/absent context.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart' show runGit;
import 'init.dart' show scaffoldVersion, hasClaudeBeginLine;
import 'model.dart';
import 'version_skew.dart';

/// One check result. [ok] false + [level] 'fail' sinks the exit code; 'note'
/// never does (used for advisory-only checks like the CI workflow).
class _Check {
  _Check(this.name,
      {required this.ok, this.level = 'fail', this.detail, this.fix});
  final String name;
  final bool ok;
  final String level; // 'fail' | 'note'
  final String? detail;
  final String? fix;

  Map<String, dynamic> toJson() => {
        'name': name,
        'ok': ok,
        'level': level,
        if (detail != null) 'detail': detail,
        if (fix != null) 'fix': fix,
      };
}

/// `int run(List<String> args)` — `doctor [--json]`. Read-only, exit 1 if any
/// check has level 'fail' and ok == false.
int run(List<String> args) {
  final asJson = args.contains('--json');
  final checks = <_Check>[
    ..._graphChecks(),
    _hookCheck(),
    _gitignoreCheck(),
    _claudeAndSkillCheck(),
    _scaffoldVersionCheck(),
    _ciCheck(),
    _monorepoCheck(),
    _lintConfigCheck(),
  ];

  final ok = !checks.any((c) => c.level == 'fail' && !c.ok);

  if (asJson) {
    stdout.writeln(jsonEncode({
      'verb': 'doctor',
      'checks': checks.map((c) => c.toJson()).toList(),
      'ok': ok,
    }));
    return ok ? 0 : 1;
  }

  for (final c in checks) {
    final prefix = c.ok ? '✓' : (c.level == 'fail' ? '✗' : '•');
    final detail = c.detail != null ? ' — ${c.detail}' : '';
    stdout.writeln('$prefix ${c.name}$detail');
    if (!c.ok && c.fix != null) stdout.writeln('  fix: ${c.fix}');
  }
  return ok ? 0 : 1;
}

/// Checks 1+2: graph present, and (if present) binary vs graph format skew.
List<_Check> _graphChecks() {
  final f = File('docs/maps/code_graph.json');
  if (!f.existsSync()) {
    return [
      _Check('graph present',
          ok: false,
          detail: 'docs/maps/code_graph.json missing',
          fix: 'codegraph build'),
      _Check('binary vs graph format',
          ok: true, level: 'note', detail: 'skipped — no graph'),
    ];
  }
  final present = _Check('graph present', ok: true);

  Map<String, dynamic>? j;
  try {
    j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return [
      present,
      _Check('binary vs graph format',
          ok: false, detail: 'graph JSON unparsable', fix: 'codegraph build'),
    ];
  }
  final fmt = (j['stats'] as Map?)?['format'] as int?;
  if (fmt == null) {
    return [
      present,
      _Check('binary vs graph format',
          ok: true,
          level: 'note',
          detail: 'graph predates format versioning',
          fix: 'codegraph build'),
    ];
  }
  if (fmt > graphFormatVersion) {
    return [
      present,
      _Check(
        'binary vs graph format',
        ok: false,
        detail:
            'graph format $fmt is newer than this binary ($graphFormatVersion)',
        fix:
            'dart pub global activate -sgit https://github.com/ArinFaraj/codegraph',
      ),
    ];
  }
  return [present, _Check('binary vs graph format', ok: true)];
}

/// Check 3: hook file present + executable + wired in a valid settings.json.
_Check _hookCheck() {
  final hook = File('.claude/hooks/code-graph-refresh.sh');
  if (!hook.existsSync()) {
    return _Check('hook installed',
        ok: false,
        detail: '.claude/hooks/code-graph-refresh.sh missing',
        fix: 'codegraph init');
  }
  final mode = hook.statSync().mode;
  final executable = (mode & 0x40) != 0; // owner-exec bit
  if (!executable) {
    return _Check('hook installed',
        ok: false, detail: 'hook is not executable', fix: 'codegraph init');
  }
  final settings = File('.claude/settings.json');
  if (!settings.existsSync()) {
    return _Check('hook installed',
        ok: false,
        detail: '.claude/settings.json missing',
        fix: 'codegraph init');
  }
  final String text;
  try {
    text = settings.readAsStringSync();
    jsonDecode(text);
  } catch (_) {
    return _Check('hook installed',
        ok: false,
        detail: '.claude/settings.json is not valid JSON',
        fix: 'codegraph init');
  }
  if (!_wiredUnderSessionStart(text)) {
    return _Check('hook installed',
        ok: false,
        detail: 'settings.json does not wire the hook under SessionStart',
        fix: 'codegraph init');
  }
  return _Check('hook installed', ok: true);
}

/// True when `settings.json`'s `hooks.SessionStart` list contains a hook
/// command referencing `code-graph-refresh.sh`. A plain substring search on
/// the raw text would false-pass when the hook is wired under the wrong
/// event (e.g. `PreToolUse`) — this parses the JSON and checks the actual
/// event key instead.
bool _wiredUnderSessionStart(String jsonText) {
  try {
    final j = jsonDecode(jsonText);
    final ss = (j is Map ? j['hooks'] : null);
    final list = (ss is Map ? ss['SessionStart'] : null);
    if (list is! List) return false;
    for (final group in list) {
      final hooks = (group is Map ? group['hooks'] : null);
      if (hooks is! List) continue;
      for (final h in hooks) {
        final cmd = (h is Map ? h['command'] : null);
        if (cmd is String && cmd.contains('code-graph-refresh.sh')) {
          return true;
        }
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Check 4: .gitignore has the graph-json line, and the file is not tracked.
_Check _gitignoreCheck() {
  const entry = 'docs/maps/code_graph.json';
  final gitignore = File('.gitignore');
  final lines = gitignore.existsSync()
      ? gitignore.readAsStringSync().split('\n').map((l) => l.trim())
      : const <String>[];
  if (!lines.contains(entry)) {
    return _Check('gitignore',
        ok: false, detail: '.gitignore missing $entry', fix: 'codegraph init');
  }
  final tracked = runGit(['ls-files', '--error-unmatch', entry]);
  if (tracked == null) {
    return _Check('gitignore',
        ok: true,
        level: 'note',
        detail: 'git not on PATH — skipped tracked check');
  }
  if (tracked.exitCode == 0) {
    return _Check('gitignore',
        ok: false,
        detail: '$entry is tracked by git',
        fix: 'git rm --cached $entry');
  }
  return _Check('gitignore', ok: true);
}

/// Check 5: CLAUDE.md marker + skill file present.
_Check _claudeAndSkillCheck() {
  final claudeMd = File('CLAUDE.md');
  if (!claudeMd.existsSync() ||
      !hasClaudeBeginLine(claudeMd.readAsStringSync())) {
    return _Check('CLAUDE.md + skill',
        ok: false,
        detail: 'CLAUDE.md missing codegraph block',
        fix: 'codegraph init');
  }
  if (!File('.claude/skills/code-map/SKILL.md').existsSync()) {
    return _Check('CLAUDE.md + skill',
        ok: false,
        detail: '.claude/skills/code-map/SKILL.md missing',
        fix: 'codegraph init');
  }
  return _Check('CLAUDE.md + skill', ok: true);
}

/// Check: installed scaffolding version vs this binary. Current → ok. Behind
/// or unknown/unparseable → note (a stale skill is degraded, not broken).
/// Absent scaffolding entirely (no hook, no CLAUDE block) → skipped note.
_Check _scaffoldVersionCheck() {
  final hasScaffold =
      File('.claude/hooks/code-graph-refresh.sh').existsSync() ||
          (File('CLAUDE.md').existsSync() &&
              hasClaudeBeginLine(File('CLAUDE.md').readAsStringSync()));
  if (!hasScaffold) {
    return _Check('scaffolding version',
        ok: true, level: 'note', detail: 'skipped — no scaffolding');
  }
  final scaffold = scaffoldVersion();
  final skew = skewOf(scaffold, binaryVersion);
  if (skew == ScaffoldSkew.current) {
    return _Check('scaffolding version', ok: true, detail: 'v$scaffold');
  }
  final versions = skew == ScaffoldSkew.unknown
      ? 'unstamped (binary v$binaryVersion)'
      : 'v$scaffold behind binary v$binaryVersion';
  return _Check('scaffolding version',
      ok: false, level: 'note', detail: versions, fix: 'codegraph upgrade');
}

/// Check 6: CI workflow present — note-level only, never fails the run.
_Check _ciCheck() {
  if (File('.github/workflows/code-graph.yml').existsSync()) {
    return _Check('CI workflow', ok: true);
  }
  return _Check('CI workflow',
      ok: false,
      level: 'note',
      detail: 'no freshness gate',
      fix: 'codegraph init --ci');
}

/// Check: `codegraph.json` parses as JSON, when present. Absent is normal
/// (config is host-authored, optional) — not a failure.
_Check _lintConfigCheck() {
  final f = File('codegraph.json');
  if (!f.existsSync()) {
    return _Check('codegraph.json',
        ok: true, level: 'note', detail: 'absent — using lint defaults');
  }
  try {
    jsonDecode(f.readAsStringSync());
  } catch (_) {
    return _Check('codegraph.json',
        ok: false,
        level: 'note',
        detail: 'malformed JSON',
        fix: 'see plans/0.7.0-lint.md config shape');
  }
  return _Check('codegraph.json', ok: true);
}

/// Check 7: package root == git root (monorepo guidance).
_Check _monorepoCheck() {
  final result = runGit(['rev-parse', '--show-toplevel']);
  if (result == null) {
    return _Check('package root == git root',
        ok: true, level: 'note', detail: 'git not on PATH — skipped');
  }
  if (result.exitCode != 0) {
    return _Check('package root == git root',
        ok: true, level: 'note', detail: 'not a git repo — skipped');
  }
  final gitRoot = (result.stdout as String).trim();
  final pkgRoot = Directory.current.resolveSymbolicLinksSync();
  if (gitRoot == pkgRoot) {
    return _Check('package root == git root', ok: true);
  }
  return _Check(
    'package root == git root',
    ok: true,
    level: 'note',
    detail:
        'monorepo — .claude/settings.json should live at the git root; the hook self-locates',
  );
}
