// `impact`: what uses a declaration, one step further, and the tests that
// reach it, seeded from a symbol, a file, or the declarations a diff touches.
import 'package:analyzer/dart/element/element.dart';

import 'declarations.dart';
import 'engine.dart';
import 'git.dart';
import 'request.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

/// What `impact` starts from.
sealed class ImpactSeed {}

class SymbolSeed extends ImpactSeed {
  SymbolSeed(this.query);
  final String query;
}

class FileSeed extends ImpactSeed {
  FileSeed(this.path);
  final String path;
}

class DiffSeed extends ImpactSeed {
  DiffSeed(this.base);
  final String? base;
}

/// The declarations an impact walk starts from, or why there are none.
sealed class Seeding {}

class Seeds extends Seeding {
  Seeds(
    this.title,
    this.targets, {
    this.notes = const [],
    this.changed = false,
  });
  final String title;
  final List<Target> targets;
  final List<String> notes;

  /// The targets are declarations a diff changed.
  final bool changed;
}

class SeedFailure extends Seeding {
  SeedFailure(this.answer);
  final Answer answer;
}

const secondStepCap = 40;

Future<Answer> impact(Engine engine, ImpactSeed seed) async =>
    switch (await _seed(engine, seed)) {
      SeedFailure(:final answer) => answer,
      final Seeds seeds => await _traverse(engine, seeds),
    };

Future<Seeding> _seed(Engine engine, ImpactSeed seed) async {
  final analysis = engine.analysis;
  switch (seed) {
    case SymbolSeed(:final query):
      return switch (await engine.resolve(query)) {
        Resolved(:final target) => Seeds(
          'impact of ${target.kind} ${target.qualified} (${target.location})',
          [target],
        ),
        final Unresolved u => SeedFailure(lookupFailure('impact', query, u)),
      };
    case FileSeed(:final path):
      final unit = await analysis.unit(path);
      return Seeds('impact of $path', [
        for (final d
            in unit == null ? const <DeclNode>[] : declarationsOf(unit.unit))
          if (!d.isMember)
            if (d.element case final e?) ?targetOf(analysis, e),
      ]);
    case DiffSeed(:final base):
      final changes = gitChanges(engine.workspace, base: base);
      if (changes == null) {
        return SeedFailure(
          MessageAnswer('impact', 'not a git repository, or `git diff` failed'),
        );
      }
      final targets = <Target>[];
      final notes = <String>[];
      for (final c in changes) {
        final (found, note) = await _changedDeclarations(engine, c);
        targets.addAll(found);
        if (note != null) notes.add(note);
      }
      return Seeds(
        'impact of ${plural(changes.length, 'changed Dart file')}'
        '${base == null ? ' in the working tree' : ' since $base'}',
        targets,
        notes: notes,
        changed: true,
      );
  }
}

/// The innermost declarations a file change's hunks touch, and a note when
/// the change cannot be mapped to declarations.
Future<(List<Target>, String?)> _changedDeclarations(
  Engine engine,
  FileChange c,
) async {
  final analysis = engine.analysis;
  if (c.deleted) {
    final importers = engine.outline.importers(c.path);
    return (
      const <Target>[],
      'deleted ${c.path}'
          '${importers.isEmpty ? '' : ', still imported by ${importers.length}: ${importers.take(5).join(', ')}'}',
    );
  }
  final unit = analysis.isAnalyzed(c.path) ? await analysis.unit(c.path) : null;
  if (unit == null) return (const <Target>[], '${c.path} is not analyzed');
  int line(int offset) => unit.lineInfo.getLocation(offset).lineNumber;
  final decls = declarationsOf(unit.unit);
  final touched = {
    for (final h in c.hunks)
      for (final d in decls)
        if (h.start <= line(d.end) && line(d.offset) <= h.end) d,
  };
  final innermost = touched.where(
    (d) => !touched.any(
      (o) =>
          o != d &&
          o.offset >= d.offset &&
          o.end <= d.end &&
          o.offset != d.offset,
    ),
  );
  return (
    [
      for (final d in innermost)
        if (d.element case final e?) ?targetOf(analysis, e),
    ],
    innermost.isEmpty && c.hunks.isNotEmpty
        ? '${c.path}: changes outside any declaration (directives or top of file)'
        : null,
  );
}

Future<Answer> _traverse(Engine engine, Seeds seeds) async {
  final analysis = engine.analysis;
  final workspace = engine.workspace;
  final seedElements = {for (final s in seeds.targets) s.element};
  final direct = <String, Set<String>>{};
  final dependents = <Element, Target>{};
  var directUses = 0;
  var subtypesTruncated = false;
  for (final s in seeds.targets) {
    final uses = await engine.usesOf(s.element);
    directUses += uses.length;
    for (final u in uses) {
      (direct[u.path] ??= {}).add(s.qualified);
      final owner = declarationOwning(u.site.enclosing).nonSynthetic;
      if (seedElements.contains(owner) || dependents.containsKey(owner)) {
        continue;
      }
      if (targetOf(analysis, owner) case final t?) dependents[owner] = t;
    }
    if (s.element case final InterfaceElement type) {
      final subs = await engine.subtypes(type);
      subtypesTruncated |= subs.truncated;
      for (final sub in subs.items) {
        if (targetOf(analysis, sub) case final t?) dependents[sub] = t;
      }
    }
  }

  final second = <String, Set<String>>{};
  for (final d in dependents.values.take(secondStepCap)) {
    for (final u in await engine.usesOf(d.element)) {
      if (!direct.containsKey(u.path)) {
        (second[u.path] ??= {}).add(d.qualified);
      }
    }
  }

  final seedFiles = {for (final s in seeds.targets) s.path};
  Map<String, Set<String>> outsideTests(Map<String, Set<String>> m) => {
    for (final p in m.keys.toList()..sort())
      if (!isTestPath(p) && !seedFiles.contains(p)) p: m[p]!,
  };
  final reached = {...direct.keys, ...second.keys}..removeAll(seedFiles);
  return ImpactAnswer(
    seeds: seeds,
    directUses: directUses,
    direct: outsideTests(direct),
    secondStep: outsideTests(second),
    tests: reached.where(isTestPath).toList()..sort(),
    publishable: [
      for (final pkg in workspace.publishablePackageRoots().map(
        workspace.relative,
      ))
        if (reached.any((f) => f.startsWith('$pkg/'))) pkg,
    ],
    partial: [
      if (dependents.length > secondStepCap)
        'second step limited to the first $secondStepCap dependents of '
            '${dependents.length}',
      if (subtypesTruncated) 'subtype walks stop at ${Engine.subtypeCap}',
    ],
  );
}

class ImpactRequest extends WorkerRequest {
  ImpactRequest(this.seed, {required super.json, required super.limit});

  factory ImpactRequest.fromJson(Map<String, dynamic> j) => ImpactRequest(
    switch (j['seed']) {
      'file' => FileSeed(j['path'] as String),
      'diff' => DiffSeed(j['base'] as String?),
      _ => SymbolSeed(j['query'] as String),
    },
    json: j['json'] as bool,
    limit: j['limit'] as int?,
  );

  final ImpactSeed seed;

  @override
  String get verb => 'impact';

  @override
  Map<String, Object?> get fields => switch (seed) {
    SymbolSeed(:final query) => {'seed': 'symbol', 'query': query},
    FileSeed(:final path) => {'seed': 'file', 'path': path},
    DiffSeed(:final base) => {'seed': 'diff', 'base': base},
  };

  @override
  Future<Answer> run(Engine engine) => impact(engine, seed);
}

class ImpactAnswer extends Answer {
  ImpactAnswer({
    required this.seeds,
    required this.directUses,
    required this.direct,
    required this.secondStep,
    required this.tests,
    required this.publishable,
    required this.partial,
  });

  final Seeds seeds;
  final int directUses;

  /// Files outside tests that use a seed, with the seeds they use.
  final Map<String, Set<String>> direct;

  /// Files outside tests reached through a dependent, with the dependents.
  final Map<String, Set<String>> secondStep;
  final List<String> tests;
  final List<String> publishable;

  /// Why the answer is incomplete; empty when it is exact.
  final List<String> partial;

  @override
  String get verb => 'impact';

  @override
  void write(TextOut out) {
    out.header(seeds.title);
    out.header(
      '${plural(seeds.targets.length, 'declaration')}'
      '${seeds.changed ? ' changed' : ''}; '
      '${plural(directUses, 'direct use')}; '
      '${plural({...direct.keys, ...secondStep.keys}.length, 'file')} outside tests and '
      '${plural(tests.length, 'test file')} reached within two steps',
    );
    for (final n in seeds.notes) {
      out.header('  $n');
    }
    out.section('uses it directly (${direct.length}):');
    for (final e in direct.entries) {
      out.row('  ${e.key}  (${e.value.take(3).join(', ')})');
    }
    out.section('one step further (${secondStep.length}):');
    for (final e in secondStep.entries) {
      out.row('  ${e.key}  (via ${e.value.take(3).join(', ')})');
    }
    out.section('tests that reference it within two steps (${tests.length}):');
    for (final p in tests) {
      out.row('  $p');
    }
    if (publishable.isNotEmpty) {
      out.footer('crosses publishable packages: ${publishable.join(', ')}');
    }
    partial.forEach(out.partial);
  }

  @override
  Map<String, Object?> toJson() => {
    'seeds': [for (final s in seeds.targets) s.toJson()],
    'notes': seeds.notes,
    'directUses': directUses,
    'direct': {for (final e in direct.entries) e.key: e.value.toList()},
    'secondStep': {for (final e in secondStep.entries) e.key: e.value.toList()},
    'tests': tests,
    'publishable': publishable,
    if (partial.isNotEmpty) 'partial': partial.join('; '),
  };
}
