// Verbs that need resolved analysis. One engine lives as long as the worker;
// [Engine.refresh] runs before every request so answers reflect the disk.
import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'classify.dart';
import 'declarations.dart';
import 'engine_answers.dart';
import 'git.dart';
import 'outline.dart';
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

class Engine {
  Engine(this.analysis) : sources = SourceCache(analysis.workspace) {
    outline = OutlineIndex.inMemory(workspace, analysis.files, sources.text);
  }

  final Analysis analysis;
  final SourceCache sources;
  late final OutlineIndex outline;

  Workspace get workspace => analysis.workspace;

  /// Syncs the analyzer with the disk and drops everything derived from the
  /// files that changed.
  Future<void> refresh() async => filesChanged(await analysis.sync());

  void filesChanged(Iterable<String> paths) {
    final list = paths.toList();
    sources.invalidate(list);
    outline.refresh(list, sources.text);
  }

  Future<Resolution> resolve(String query) => resolveSymbol(analysis, query);

  /// The element and the accessors, variable and getter/setter partners that
  /// share its name, so a property's uses are counted once, completely.
  Set<Element> propertyFamily(Element e) => switch (e) {
    PropertyInducingElement() => {e, ?e.getter, ?e.setter},
    GetterElement() => {e, e.variable, ?e.correspondingSetter},
    SetterElement() => {e, e.variable, ?e.correspondingGetter},
    _ => {e},
  };

  Future<List<Use>> usesOf(Element e) async {
    final sites = <String, Site>{};
    for (final member in propertyFamily(e)) {
      for (final s in await analysis.references(member)) {
        sites.putIfAbsent(s.key, () => s);
      }
    }
    return [
      for (final s
          in sites.values.toList()..sort((a, b) {
            final c = a.path.compareTo(b.path);
            return c != 0 ? c : a.offset.compareTo(b.offset);
          }))
        classify(s, sources),
    ];
  }

  static const subtypeCap = 500;

  /// Every subtype of [type], transitively, within the workspace.
  Future<({List<InterfaceElement> types, bool truncated})> subtypes(
    InterfaceElement type,
  ) async {
    final out = <InterfaceElement>[];
    final seen = <String>{};
    final queue = [type];
    while (queue.isNotEmpty) {
      for (final s in await analysis.directSubtypes(queue.removeLast())) {
        final at = analysis.locate(s);
        if (at == null || !seen.add('${at.path}:${at.offset}')) continue;
        if (out.length == subtypeCap) return (types: out, truncated: true);
        out.add(s);
        queue.add(s);
      }
    }
    return (types: out, truncated: false);
  }

  /// Instance members named like [member] across its class hierarchy: the
  /// members it overrides, the ones overriding it, and their siblings
  /// through shared supertypes. Renaming one means renaming all.
  Future<List<Element>> overrideSet(Element member) async {
    final owner = member.enclosingElement;
    if (!isInstanceMember(member) || owner is! InterfaceElement) {
      return [member.nonSynthetic];
    }
    final classes = <InterfaceElement>{
      owner,
      for (final t in owner.allSupertypes) t.element,
    };
    for (final c in classes.toList()) {
      if (analysis.locate(c) == null) continue;
      classes.addAll((await subtypes(c)).types);
    }
    return {
      for (final c in classes)
        for (final m in [...c.fields, ...c.getters, ...c.setters, ...c.methods])
          if (m.name == member.name && isInstanceMember(m)) m.nonSynthetic,
    }.toList();
  }

  Future<Answer> refs(String query) async {
    final r = await resolve(query);
    if (failureOf('refs', query, r) case final failure?) return failure;
    final target = (r as Resolved).target;
    return RefsAnswer(target, await usesOf(target.element), analysis.fileCount);
  }

  Future<Answer> showSymbol(String query) async {
    final r = await resolve(query);
    if (failureOf('show', query, r) case final failure?) return failure;
    final t = (r as Resolved).target;
    final e = t.element;
    final declared = await declarationOf(analysis, t);
    final subs = e is InterfaceElement ? await subtypes(e) : null;
    return ShowSymbolAnswer(
      target: t,
      query: query,
      signature: declared?.$1.sig ?? e.displayName,
      doc: declared?.$1.doc,
      members: [
        for (final m in declared?.$2 ?? const <DeclNode>[])
          (sources.lineOf(t.path, m.nameOffset), m.sig),
      ],
      supertypes: e is InterfaceElement
          ? [
              for (final s in e.allSupertypes)
                if (!(s.element.name == 'Object' &&
                    s.element.library.isDartCore))
                  s.getDisplayString(),
            ]
          : const [],
      subtypes: [
        for (final s in subs?.types ?? const []) ?targetOf(analysis, s),
      ],
      subtypesTruncated: subs?.truncated ?? false,
      overrides: [
        if (isInstanceMember(e))
          for (final m in await overrideSet(e))
            if (m != e.nonSynthetic) ?targetOf(analysis, m),
      ],
      uses: await usesOf(e),
    );
  }

  Future<Answer> impact(ImpactSeed seed) async {
    final notes = <String>[];
    final List<Target> seeds;
    final String title;
    switch (seed) {
      case SymbolSeed(:final query):
        final r = await resolve(query);
        if (failureOf('impact', query, r) case final failure?) return failure;
        final t = (r as Resolved).target;
        seeds = [t];
        title = 'impact of ${t.kind} ${t.qualified} (${t.location})';
      case FileSeed(:final path):
        seeds = await _fileSeeds(path);
        title = 'impact of $path';
      case DiffSeed(:final base):
        final changes = gitChanges(workspace, base: base);
        if (changes == null) {
          return MessageAnswer(
            'impact',
            'not a git repository, or `git diff` failed',
          );
        }
        seeds = await _diffSeeds(changes, notes);
        title =
            'impact of ${plural(changes.length, 'changed Dart file')}'
            '${base == null ? ' in the working tree' : ' since $base'}';
    }
    return _traverse(title, seeds, notes, changed: seed is DiffSeed);
  }

  Future<List<Target>> _fileSeeds(String path) async {
    final unit = await analysis.unit(path);
    if (unit == null) return const [];
    return [
      for (final d in declarationsOf(unit.unit))
        if (!d.isMember)
          if (d.element case final e?)
            if (targetOf(analysis, e) case final t?) t,
    ];
  }

  /// The innermost declarations each hunk touches.
  Future<List<Target>> _diffSeeds(
    List<FileChange> changes,
    List<String> notes,
  ) async {
    final seeds = <Target>[];
    for (final c in changes) {
      if (c.deleted) {
        final importers = outline.importers(c.path);
        notes.add(
          'deleted ${c.path}'
          '${importers.isEmpty ? '' : ', still imported by ${importers.length}: ${importers.take(5).join(', ')}'}',
        );
        continue;
      }
      final unit = analysis.isAnalyzed(c.path)
          ? await analysis.unit(c.path)
          : null;
      if (unit == null) {
        notes.add('${c.path} is not analyzed');
        continue;
      }
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
      if (innermost.isEmpty && c.hunks.isNotEmpty) {
        notes.add(
          '${c.path}: changes outside any declaration (directives or top of file)',
        );
      }
      for (final d in innermost) {
        if (d.element case final e?) seeds.addAll([?targetOf(analysis, e)]);
      }
    }
    return seeds;
  }

  static const secondStepCap = 40;

  Future<Answer> _traverse(
    String title,
    List<Target> seeds,
    List<String> notes, {
    required bool changed,
  }) async {
    final seedElements = {for (final s in seeds) s.element};
    final direct = <String, Set<String>>{};
    final dependents = <Element, Target>{};
    var directUses = 0;
    for (final s in seeds) {
      final uses = await usesOf(s.element);
      directUses += uses.length;
      for (final u in uses) {
        (direct[u.path] ??= {}).add(s.qualified);
        final owner = declarationOwning(u.site.enclosing).nonSynthetic;
        if (seedElements.contains(owner) || dependents.containsKey(owner))
          continue;
        if (targetOf(analysis, owner) case final t?) dependents[owner] = t;
      }
      if (s.element case final InterfaceElement type) {
        for (final sub in (await subtypes(type)).types) {
          if (targetOf(analysis, sub) case final t?) dependents[sub] = t;
        }
      }
    }

    final second = <String, Set<String>>{};
    for (final d in dependents.values.take(secondStepCap)) {
      for (final u in await usesOf(d.element)) {
        if (!direct.containsKey(u.path))
          (second[u.path] ??= {}).add(d.qualified);
      }
    }

    final seedFiles = {for (final s in seeds) s.path};
    List<String> outsideTests(Map<String, Set<String>> m) =>
        m.keys.where((p) => !isTestPath(p) && !seedFiles.contains(p)).toList()
          ..sort();
    final reached = {...direct.keys, ...second.keys}..removeAll(seedFiles);
    return ImpactAnswer(
      title: title,
      changed: changed,
      seeds: seeds,
      notes: notes,
      directUses: directUses,
      direct: {for (final p in outsideTests(direct)) p: direct[p]!},
      secondStep: {for (final p in outsideTests(second)) p: second[p]!},
      tests: reached.where(isTestPath).toList()..sort(),
      publishable: [
        for (final pkg in workspace.publishablePackageRoots().map(
          workspace.relative,
        ))
          if (reached.any((f) => f.startsWith('$pkg/'))) pkg,
      ],
      truncatedDependents: dependents.length > secondStepCap
          ? dependents.length
          : null,
    );
  }
}
