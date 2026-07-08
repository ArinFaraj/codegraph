// `codegraph diff [--base <ref>]` — branch blast-radius card: what changed
// vs a base ref, what it touches, what's untested. Verb-only (never
// committed) — every git call here is allowed but MUST be guarded against
// `ProcessException` (missing git) exactly like `attention.dart`'s
// `_lastCommitEpoch`, so a broken toolchain prints a one-line error instead
// of crashing.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'impact.dart';
import 'lint.dart' as lint;
import 'model.dart';

const _testRoots = ['test/', 'integration_test/', 'patrol_test/'];

bool _isTracked(String path) =>
    path.endsWith('.dart') &&
    (path.startsWith('lib/') ||
        RegExp(r'^packages/[^/]+/lib/').hasMatch(path) ||
        _testRoots.any(path.startsWith));

bool _isTestPath(String path) => _testRoots.any(path.startsWith);

/// One changed file: its status (A/M/D — renames are pre-split into D+A by
/// the caller) and repo-relative path.
class _Change {
  _Change(this.status, this.path);
  final String status; // 'A' | 'M' | 'D'
  final String path;
}

/// Runs `cmd` via `Process.runSync`, returning `null` (never throwing) if the
/// executable can't be resolved — the MANDATORY guard for every git call in
/// this file, same pattern as `attention.dart`'s `_lastCommitEpoch`.
ProcessResult? _run(List<String> cmd) {
  try {
    return Process.runSync(cmd.first, cmd.skip(1).toList());
  } on ProcessException {
    return null;
  }
}

/// Result of an auto-base lookup: either a resolved [ref], or [gitMissing]
/// set when the very first git invocation threw `ProcessException` (git not
/// on PATH) — distinguished from "git ran fine but no candidate ref exists"
/// so the caller can print the right one-line error instead of always
/// blaming the missing `--base`.
class _AutoBaseResult {
  _AutoBaseResult.found(this.ref) : gitMissing = false;
  _AutoBaseResult.noneFound()
      : ref = null,
        gitMissing = false;
  _AutoBaseResult.gitNotFound()
      : ref = null,
        gitMissing = true;
  final String? ref;
  final bool gitMissing;
}

/// First of `origin/main`, `main`, `master` that git actually knows about.
_AutoBaseResult _autoBase() {
  for (final ref in ['origin/main', 'main', 'master']) {
    final r = _run(['git', 'rev-parse', '--verify', '-q', ref]);
    if (r == null) return _AutoBaseResult.gitNotFound();
    if (r.exitCode == 0) return _AutoBaseResult.found(ref);
  }
  return _AutoBaseResult.noneFound();
}

/// `git merge-base <base> HEAD`, trimmed — falls back to `base` itself (e.g.
/// shallow clones where merge-base can't be computed) rather than failing.
String _mergeBase(String base) {
  final r = _run(['git', 'merge-base', base, 'HEAD']);
  if (r == null || r.exitCode != 0) return base;
  final sha = (r.stdout as String).trim();
  return sha.isEmpty ? base : sha;
}

/// Parses `git diff --name-status <mergeBase>` output. `Rxxx\told\tnew`
/// lines become a D(old) + A(new) pair (plan 3.1: "treat as D(old)+A(new)").
List<_Change> _parseNameStatus(String out) {
  final changes = <_Change>[];
  for (final line in out.split('\n')) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('\t');
    final status = parts[0];
    if (status.startsWith('R')) {
      if (parts.length >= 3) {
        changes.add(_Change('D', parts[1]));
        changes.add(_Change('A', parts[2]));
      }
      continue;
    }
    if (parts.length >= 2) {
      changes.add(_Change(status, parts[1]));
    }
  }
  return changes;
}

String _short(String sha) => sha.length > 7 ? sha.substring(0, 7) : sha;

/// Area of a repo-relative path: `lib/<area>` or `packages/<pkg>/lib`
/// (matches `engine.dart`'s `_writeAllAreaMaps` grouping: `segs[0]/segs[1]`).
String _areaOf(String path) {
  final segs = path.split('/');
  if (segs.length < 2) return path;
  return '${segs[0]}/${segs[1]}';
}

List<String> _cappedList(List<String> lines, int cap) {
  if (lines.length <= cap) return lines;
  final shown = lines.take(cap).toList();
  shown.add('… ${lines.length - cap} more (raise --budget)');
  return shown;
}

const _untestedRoles = {'view', 'controller', 'repository', 'provider'};

/// `int run(List<String> args)` — `diff [--base <ref>] [--json] [--budget N]`.
int run(List<String> args) {
  final asJson = args.contains('--json');
  final budget = intFlag(args, '--budget') ?? 150;
  // Per-section text cap: compact by default (a readable CI card), but
  // `--budget N` expands EVERY section so the full changed-but-untested /
  // blast-radius lists are reachable (they were previously unreachable — text
  // hard-capped at 10, `--json` starved them; found by an A/B eval).
  final sectionCap = intFlag(args, '--budget') ?? 10;
  final baseFlag = _stringFlag(args, '--base');

  final String base;
  if (baseFlag != null) {
    final verify = _run(['git', 'rev-parse', '--verify', '-q', baseFlag]);
    if (verify == null) {
      stderr.writeln('git not found on PATH');
      return 1;
    }
    if (verify.exitCode != 0) {
      stderr.writeln('no base found — pass --base <ref>');
      return 1;
    }
    base = baseFlag;
  } else {
    final auto = _autoBase();
    if (auto.gitMissing) {
      stderr.writeln('git not found on PATH');
      return 1;
    }
    if (auto.ref == null) {
      stderr.writeln('no base found — pass --base <ref>');
      return 1;
    }
    base = auto.ref!;
  }

  final mergeBase = _mergeBase(base);
  final diffResult = _run(['git', 'diff', '--name-status', mergeBase]);
  if (diffResult == null) {
    stderr.writeln('git not found on PATH');
    return 1;
  }
  if (diffResult.exitCode != 0) {
    stderr.writeln('git diff failed: ${(diffResult.stderr as String).trim()}');
    return 1;
  }

  final changes = _parseNameStatus(diffResult.stdout as String)
      .where((c) => _isTracked(c.path))
      .toList();

  // Untracked files (new, never `git add`ed) are invisible to `git diff
  // --name-status` — a branch that adds a provider file but forgets to stage
  // it would otherwise show 0 changes. `--exclude-standard` keeps gitignored
  // build artifacts out by construction; same ProcessException guard as
  // every other git call here.
  final untrackedResult =
      _run(['git', 'ls-files', '--others', '--exclude-standard']);
  if (untrackedResult != null && untrackedResult.exitCode == 0) {
    final changedPaths = changes.map((c) => c.path).toSet();
    for (final line in (untrackedResult.stdout as String).split('\n')) {
      final path = line.trim();
      if (path.isEmpty || !_isTracked(path)) continue;
      if (changedPaths.contains(path)) continue;
      changes.add(_Change('A', path));
      changedPaths.add(path);
    }
  }

  if (changes.isEmpty) {
    stdout.writeln('no dart changes vs $base');
    return 0;
  }

  final graph = Graph.load();
  if (graph == null) return 66;

  final libChanges = changes.where((c) => !_isTestPath(c.path)).toList();
  final testChanges = changes.where((c) => _isTestPath(c.path)).toList();

  // A path can appear as both D and A only via a rename split above — dedupe
  // isn't needed for that case (D(old) and A(new) are different paths).
  final changedLibPaths = libChanges.map((c) => c.path).toSet();

  GraphNode? nodeFor(String path) => graph.byId['file:$path'];

  // 2. areas touched
  final areaCounts = <String, int>{};
  for (final c in libChanges) {
    areaCounts.update(_areaOf(c.path), (v) => v + 1, ifAbsent: () => 1);
  }
  final areaLines = (areaCounts.keys.toList()
        ..sort((a, b) {
          final byCount = areaCounts[b]!.compareTo(areaCounts[a]!);
          return byCount != 0 ? byCount : a.compareTo(b);
        }))
      .map((a) => '  $a (${areaCounts[a]})')
      .toList();

  // 3. high in-degree changes — changed lib files (any status) sorted inDeg
  // desc then name, top 10.
  final changedLibNodes =
      libChanges.map((c) => nodeFor(c.path)).whereType<GraphNode>().toList();
  int inDeg(GraphNode n) => graph.inDeg[n.id] ?? 0;
  final highInDeg = changedLibNodes.toList()
    ..sort((a, b) {
      final byDeg = inDeg(b).compareTo(inDeg(a));
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  final highInDegLines = highInDeg
      .map((n) =>
          '  ${n.id.replaceFirst('file:', '')} [${n.role}]${inDegSuffix(graph.inDeg[n.id] ?? 0)}')
      .toList();

  // 4. providers in changed files — declared in a changed lib file; mark
  // ' (new)' when the declaring file's status is A.
  final addedPaths =
      libChanges.where((c) => c.status == 'A').map((c) => c.path).toSet();
  final providerLines = <String>[];
  final changedProviderNodes = graph.nodes
      .where((n) =>
          n.isProvider &&
          n.declaredIn != null &&
          changedLibPaths.contains(n.declaredIn))
      .toList()
    ..sort((a, b) {
      final byDeg = (graph.inDeg[b.id] ?? 0).compareTo(graph.inDeg[a.id] ?? 0);
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  for (final n in changedProviderNodes) {
    final readers = graph.inDeg[n.id] ?? 0;
    final isNew = addedPaths.contains(n.declaredIn) ? ' (new)' : '';
    providerLines
        .add('  ${n.name} — $readers reader(s) — ${n.declaredIn}$isNew');
  }

  // 5. changed pages — role view.
  final pageLines = changedLibNodes
      .where((n) => n.role == 'view')
      .toList()
      .map((n) => '  ${n.id.replaceFirst('file:', '')}')
      .toList()
    ..sort();

  // 6. deleted but still imported — D-status files that are dst of an
  // `imports` edge in the CURRENT graph.
  final deletedPaths =
      libChanges.where((c) => c.status == 'D').map((c) => c.path).toSet();
  final importersOf = <String, List<String>>{};
  for (final e in graph.edges) {
    if (e.rel != 'imports') continue;
    if (!e.dst.startsWith('file:')) continue;
    final dstPath = e.dst.replaceFirst('file:', '');
    if (deletedPaths.contains(dstPath)) {
      importersOf
          .putIfAbsent(dstPath, () => [])
          .add(e.src.replaceFirst('file:', ''));
    }
  }
  final deletedButImportedPaths = (importersOf.keys.toList()..sort());
  final deletedButImportedLines = deletedButImportedPaths.map((p) {
    final importers = importersOf[p]!..sort();
    return '  $p  <- ${joinCapped(importers.take(3).toList())}'
        '${importers.length > 3 ? ' (+${importers.length - 3} more)' : ''}';
  }).toList();

  // 7. changed but untested — changed lib files, testRefs==0, role in the
  // Standard-07-shaped set.
  final untestedLines = changedLibNodes
      .where((n) => n.testRefs == 0 && _untestedRoles.contains(n.role))
      .toList()
    ..sort((a, b) {
      final byDeg = inDeg(b).compareTo(inDeg(a));
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  final untestedRenderLines = untestedLines
      .map((n) =>
          '  ${n.id.replaceFirst('file:', '')} [${n.role}]${inDegSuffix(graph.inDeg[n.id] ?? 0)}')
      .toList();

  // 8. blast radius (depth 1) — dependentsOf ALL changed lib files (as file
  // ids), excluding the changed files themselves.
  final changedFileIds = changedLibPaths.map((p) => 'file:$p').toSet();
  final blast = dependentsOf(graph, changedFileIds)
      .where((id) => id.startsWith('file:') && !changedFileIds.contains(id))
      .map((id) => graph.byId[id])
      .whereType<GraphNode>()
      .toList()
    ..sort((a, b) {
      final byDeg = inDeg(b).compareTo(inDeg(a));
      return byDeg != 0 ? byDeg : a.id.compareTo(b.id);
    });
  final blastLines = blast
      .map((n) =>
          '  ${n.id.replaceFirst('file:', '')}${inDegSuffix(graph.inDeg[n.id] ?? 0)}')
      .toList();

  // Lint reuse: never let a config/baseline hiccup crash the diff card — this
  // verb's job is the blast-radius summary, lint is a bonus line on top.
  int lintNew = 0;
  try {
    lintNew = lint.newViolations(graph).length;
  } catch (_) {
    lintNew = 0;
  }

  if (asJson) {
    // Each section is capped INDEPENDENTLY at `budget` — NOT via one shared
    // Budget consumed in order, which starved the last (decision-relevant)
    // sections to [] once earlier big sections (highInDegree) used it up. That
    // silently dropped changedButUntested/blastRadius/providers/pages from the
    // machine path entirely (found by an A/B eval). `truncated` is set if ANY
    // section exceeded its cap. Raise --budget to get more per section.
    var truncatedAny = false;
    List<T> capSec<T>(List<T> l) {
      if (l.length > budget) truncatedAny = true;
      return l.take(budget).toList();
    }

    final appLib = libChanges.where((c) => c.path.startsWith('lib/')).length;
    final pkgLib = libChanges.length - appLib;
    final json = {
      'verb': 'diff',
      'base': base,
      'mergeBase': mergeBase,
      // `lib` kept for back-compat (app + package lib); split out so a consumer
      // isn't misled into reading it as app-only.
      'files': {
        'lib': libChanges.length,
        'appLib': appLib,
        'pkgLib': pkgLib,
        'test': testChanges.length,
      },
      'areasTouched': capSec(
        (areaCounts.keys.toList()
              ..sort((a, b) {
                final byCount = areaCounts[b]!.compareTo(areaCounts[a]!);
                return byCount != 0 ? byCount : a.compareTo(b);
              }))
            .map((a) => {'area': a, 'count': areaCounts[a]})
            .toList(),
      ),
      'highInDegree': capSec(
        highInDeg
            .map((n) => {
                  'file': n.id.replaceFirst('file:', ''),
                  'role': n.role,
                  'inDeg': inDeg(n),
                })
            .toList(),
      ),
      'providers': capSec(
        changedProviderNodes
            .map((n) => {
                  'name': n.name,
                  'declaredIn': n.declaredIn,
                  'readers': graph.inDeg[n.id] ?? 0,
                  'isNew': addedPaths.contains(n.declaredIn),
                })
            .toList(),
      ),
      'pages': capSec(
        changedLibNodes
            .where((n) => n.role == 'view')
            .map((n) => n.id.replaceFirst('file:', ''))
            .toList()
          ..sort(),
      ),
      'deletedButImported': capSec(
        deletedButImportedPaths
            .map((p) => {'file': p, 'importers': importersOf[p]!..sort()})
            .toList(),
      ),
      'changedButUntested': capSec(
        untestedLines
            .map((n) => {
                  'file': n.id.replaceFirst('file:', ''),
                  'role': n.role,
                  'inDeg': inDeg(n),
                })
            .toList(),
      ),
      'blastRadius': capSec(
        blast
            .map((n) => {
                  'file': n.id.replaceFirst('file:', ''),
                  'inDeg': inDeg(n),
                })
            .toList(),
      ),
      if (lintNew > 0) 'lintNewViolations': lintNew,
      if (truncatedAny) 'truncated': true,
    };
    stdout.writeln(jsonEncode(json));
    return 0;
  }

  final out = <String>[
    'diff vs $base (merge-base ${_short(mergeBase)})',
    '${libChanges.length + testChanges.length} dart files changed '
        '(${libChanges.length} lib · ${testChanges.length} test)',
    '',
    'areas touched:',
    ...(areaLines.isEmpty ? ['  (none)'] : _cappedList(areaLines, sectionCap)),
    '',
    'high in-degree changes:',
    ...(highInDegLines.isEmpty
        ? ['  (none)']
        : _cappedList(highInDegLines, sectionCap)),
    '',
    'providers in changed files:',
    ...(providerLines.isEmpty
        ? ['  (none)']
        : _cappedList(providerLines, sectionCap)),
    '',
    'changed pages:',
    ...(pageLines.isEmpty ? ['  (none)'] : _cappedList(pageLines, sectionCap)),
    '',
    'deleted but still imported:',
    ...(deletedButImportedLines.isEmpty
        ? ['  (none)']
        : _cappedList(deletedButImportedLines, sectionCap)),
    '',
    'changed but untested:',
    ...(untestedRenderLines.isEmpty
        ? ['  (none)']
        : _cappedList(untestedRenderLines, sectionCap)),
    '',
    'blast radius (depth 1) (${blastLines.length}):',
    ...(blastLines.isEmpty
        ? ['  (none)']
        : _cappedList(blastLines, sectionCap)),
    if (lintNew > 0) ...[
      '',
      'lint: $lintNew new architecture violation(s) — codegraph lint',
    ],
  ];

  // Per-section caps already bound the output; don't apply a total line cap on
  // top (it re-starved later sections). Each section carries its own "N more".
  emit(out, out.length);
  return 0;
}

String? _stringFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}
