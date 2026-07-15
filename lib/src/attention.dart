// `docs/maps/ATTENTION.md` (written by `build()`) and `codegraph attention`
// (query verb) — a triage surface for human reviewers and agents: the graph
// shapes that need a human judgment call, not just a lookup.
//
// Both the committed file and the verb render the SAME sections from the
// SAME computation (`attentionSections`), so they can never drift out of
// sync with each other. The verb adds one more, nondeterministic,
// verb-only section (`## Possibly stale notes`, Stage 3) that must never be
// written to the committed file — that's the one asymmetry, and it's
// enforced by the caller (build() doesn't call the verb-only section).
import 'dart:io';

import 'cli_util.dart' show intFlag, runGit;
import 'freshness.dart';
import 'model.dart';

const _header = '''
# ATTENTION

_What needs a human. Regenerate via `codegraph build`. Every entry here is a
candidate, not a verdict — confirm before acting. "test-only" counts are a
token-name match against test source, not a resolved reference — same
candidate-data caveat._
''';

/// One `## Section` heading + its sorted, already-capped body lines (no cap
/// marker line — that's added by the renderer so both the md writer and the
/// verb apply the SAME "… N more" convention).
class AttentionSection {
  AttentionSection(this.title, this.entries, this.totalCount);
  final String title;
  final List<String> entries; // capped to 20 by the caller
  final int totalCount; // uncapped count, for the "… N more" line
}

const _sectionCap = 20;

List<String> _capped(List<String> lines) {
  if (lines.length <= _sectionCap) return lines;
  final shown = lines.take(_sectionCap).toList();
  shown.add('… ${lines.length - _sectionCap} more');
  return shown;
}

/// Ambiguous providers: name declared >1x, each with its declaration files
/// and the count of unresolved reader edges (watches/reads/listens edges the
/// resolver couldn't narrow to one declaration — see model.dart's sentinel
/// doc). One line per name, sorted by name.
AttentionSection _ambiguousProviders(Graph graph) {
  final byName = <String, List<GraphNode>>{};
  for (final n in graph.nodes) {
    if (n.isProvider && n.isAmbiguousProvider) {
      byName.putIfAbsent(n.name!, () => []).add(n);
    }
  }
  final names = byName.keys.toList()..sort();
  final lines = <String>[];
  for (final name in names) {
    final files = (byName[name]!.map((n) => n.declaredIn!).toList()..sort());
    final unresolved = graph.edges.where(
      (e) =>
          e.dst == 'provider:$name' &&
          e.isUnresolvedAmbiguous &&
          providerConsumerRels.contains(e.rel),
    );
    lines.add(
      '- `$name` — declared in ${files.map((f) => '`$f`').join(', ')} '
      '— ${unresolved.length} unresolved reader edge(s)',
    );
  }
  return AttentionSection('Ambiguous providers', _capped(lines), lines.length);
}

/// Reuses `Graph.unusedProviders` (shared with `query.dart`'s
/// `unused providers`) — one implementation, two call sites.
AttentionSection _zeroConsumerProviders(Graph graph) {
  final lines = graph.unusedProviders
      .map(
        (n) => '- `${n.id.replaceFirst('provider:', '')}` '
            '— ${n.providerType} — ${n.declaredIn}${n.testOnlySuffix}',
      )
      .toList();
  return AttentionSection(
    'Providers with zero consumers',
    _capped(lines),
    lines.length,
  );
}

/// Reuses `Graph.orphanFiles` (shared with `query.dart`'s `unused files`),
/// including its entrypoint exclusions.
AttentionSection _orphanFiles(Graph graph) {
  final lines = graph.orphanFiles
      .map(
        (n) =>
            '- `${n.id.replaceFirst('file:', '')}` [${n.role}]${n.testOnlySuffix}',
      )
      .toList();
  return AttentionSection(
      'Files nothing imports', _capped(lines), lines.length);
}

/// Same class/enum/mixin name declared in 2+ files — one pass over every
/// file node's symbol records, grouped by (kind, name) so a class and an enum
/// that happen to share a name aren't conflated.
AttentionSection _duplicateSymbolNames(Graph graph) {
  final byKindName = <String, List<String>>{}; // "kind:name" -> files
  for (final n in graph.nodes) {
    if (!n.isFile) continue;
    for (final s in n.symbols) {
      if (s.kind != 'class' && s.kind != 'enum' && s.kind != 'mixin') {
        continue;
      }
      byKindName
          .putIfAbsent('${s.kind}:${s.name}', () => [])
          .add(n.id.replaceFirst('file:', ''));
    }
  }
  final dupKeys = byKindName.keys
      .where((k) => byKindName[k]!.toSet().length > 1)
      .toList()
    ..sort();
  final lines = <String>[];
  for (final key in dupKeys) {
    final colon = key.indexOf(':');
    final kind = key.substring(0, colon);
    final name = key.substring(colon + 1);
    final files = (byKindName[key]!.toSet().toList()..sort());
    lines.add(
      '- `$name` ($kind) — ${files.map((f) => '`$f`').join(', ')}',
    );
  }
  return AttentionSection(
      'Duplicate symbol names', _capped(lines), lines.length);
}

/// `navigates` edges whose target expression (after the `route:` prefix)
/// doesn't start with a quote — i.e. it's an indirection (a constant, a
/// variable, an interpolated string) an agent can't follow from the graph
/// without reading the source. Excludes any `navigates` edge that carries no
/// `unresolved` flag (Stage 4 resolved it) — [GraphEdge.unresolved] is
/// authoritative, set at emission time, so this never re-derives resolution
/// via a (src, line) join.
AttentionSection _unresolvedNavigation(Graph graph) {
  final lines = <String>[];
  for (final e in graph.edges) {
    if (e.rel != 'navigates') continue;
    if (!e.unresolved) continue;
    final expr = e.dst.replaceFirst('route:', '');
    if (expr.startsWith("'") || expr.startsWith('"')) continue;
    lines.add(
      '- `${e.src.replaceFirst('file:', '')}` → `$expr`'
      '${e.line != null ? ':${e.line}' : ''}',
    );
  }
  lines.sort();
  return AttentionSection(
    'Unresolved navigation',
    _capped(lines),
    lines.length,
  );
}

/// The five deterministic sections, in header order — shared by both the
/// committed ATTENTION.md and the `attention` verb so they can never diverge.
List<AttentionSection> attentionSections(Graph graph) => [
      _ambiguousProviders(graph),
      _zeroConsumerProviders(graph),
      _orphanFiles(graph),
      _duplicateSymbolNames(graph),
      _unresolvedNavigation(graph),
    ];

String _renderSection(AttentionSection s) {
  final b = StringBuffer()
    ..writeln('## ${s.title}')
    ..writeln();
  if (s.entries.isEmpty) {
    b.writeln('(none)');
  } else {
    for (final e in s.entries) {
      b.writeln(e);
    }
  }
  b.writeln();
  return b.toString();
}

/// Renders the deterministic sections (no trailing verb-only content) — used
/// by both `build()` (writes to disk) and the `attention` verb (before it
/// appends its own verb-only, nondeterministic section).
String renderAttention(Graph graph) {
  final b = StringBuffer()..writeln(_header);
  for (final s in attentionSections(graph)) {
    b.write(_renderSection(s));
  }
  return b.toString();
}

/// `codegraph build` calls this to write the committed, deterministic
/// ATTENTION.md. Byte-identical for identical source (constraint #2) — no
/// verb-only sections here.
void writeAttentionMd(Graph graph) {
  File('docs/maps/ATTENTION.md').writeAsStringSync(renderAttention(graph));
}

/// Last-commit epoch seconds for a git-tracked path, or null if git fails,
/// isn't installed, or the path is untracked (empty stdout) — all three
/// cases mean "skip silently": staleness detection is a nice-to-have, never
/// a hard requirement.
int? _lastCommitEpoch(String path) {
  final result = runGit(['log', '-1', '--format=%ct', '--', path]);
  if (result == null) return null;
  if (result.exitCode != 0) return null;
  final out = (result.stdout as String).trim();
  if (out.isEmpty) return null;
  return int.tryParse(out);
}

String _isoDate(int epochSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
        .toIso8601String()
        .substring(0, 10);

/// `## Possibly stale notes` — verb-only: this section is intentionally
/// nondeterministic (depends on git history at run time) so it must never be
/// written to the committed, byte-stable ATTENTION.md. For each
/// `docs/maps/notes/*.md`, compares the
/// note's last-commit time to the newest last-commit time of any file under
/// its area's source dir (`lib/<area>` or `packages/<area>`, whichever
/// exists). Flags notes whose area moved after the note was last touched.
/// Bounded git calls: one `git log` per note + one per involved area.
List<String> _staleNotesLines() {
  final dir = Directory('docs/maps/notes');
  if (!dir.existsSync()) return const [];
  final notes = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (notes.isEmpty) return const [];

  final flagged = <String>[];
  final areaTimeCache = <String, int?>{};
  for (final note in notes) {
    final notePath = note.path;
    final noteTime = _lastCommitEpoch(notePath);
    if (noteTime == null) continue; // git unavailable / untracked — skip

    final area = notePath.substring(
        notePath.lastIndexOf('/') + 1, notePath.length - '.md'.length);
    final libDir =
        Directory('lib/$area').existsSync() ? 'lib/$area' : 'packages/$area';
    final areaTime = areaTimeCache.putIfAbsent(
      libDir,
      () => _lastCommitEpoch(libDir),
    );
    if (areaTime == null) continue;

    if (areaTime > noteTime) {
      flagged.add(
        '- $notePath  (note ${_isoDate(noteTime)} < area ${_isoDate(areaTime)})',
      );
    }
  }
  flagged.sort();
  return flagged;
}

/// `codegraph attention` — prints the same sections as the committed
/// ATTENTION.md, computed fresh from `Graph.load()` (never reads the .md
/// file), PLUS the verb-only `## Possibly stale notes` section — omitted from
/// the committed file because it's nondeterministic. Respects `--budget` (default 80)
/// as a total line cap across the whole rendered output, same convention as
/// every other query verb.
int run(List<String> args) {
  final graph = loadFresh();
  if (graph == null) return 66;
  final budget = intFlag(args, '--budget') ?? 80;

  final buf = StringBuffer(renderAttention(graph));
  final stale = _staleNotesLines();
  if (stale.isNotEmpty) {
    buf.write(_renderSection(
      AttentionSection('Possibly stale notes', stale, stale.length),
    ));
  }

  final lines = buf.toString().split('\n');
  // Drop the single trailing blank line from the last section's writeln() so
  // budget counting doesn't waste a slot on it.
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  for (final l in lines.take(budget)) {
    stdout.writeln(l);
  }
  if (lines.length > budget) {
    stdout.writeln(
      '… ${lines.length - budget} more (raise --budget to see all)',
    );
  }
  return 0;
}
