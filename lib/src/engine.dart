// Verbs that need resolved analysis. They run inside the worker, after the
// worker has synced with the disk, so every answer reflects the files as they
// are now and covers every analyzed file.
import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'classify.dart';
import 'git.dart';
import 'outline.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

class Engine {
  Engine(this.analysis);

  final Analysis analysis;
  final SourceCache sources = SourceCache();

  Workspace get workspace => analysis.workspace;

  OutlineIndex outlines() =>
      OutlineIndex.load(workspace, analyzedFiles: analysis.files.toList());

  /// The element and the accessors, variable and getter/setter partners that
  /// share its name, so a property's uses are counted once, completely.
  Set<Element> propertyFamily(Element e) {
    final out = <Element>{e};
    if (e is PropertyInducingElement) {
      if (e.getter != null) out.add(e.getter!);
      if (e.setter != null) out.add(e.setter!);
    } else if (e is GetterElement) {
      out.add(e.variable);
      if (e.correspondingSetter != null) out.add(e.correspondingSetter!);
    } else if (e is SetterElement) {
      out.add(e.variable);
      if (e.correspondingGetter != null) out.add(e.correspondingGetter!);
    }
    return out;
  }

  Future<List<Site>> sitesOf(Element e) async {
    final out = <String, Site>{};
    for (final member in propertyFamily(e)) {
      for (final s in await analysis.references(member)) {
        out.putIfAbsent(s.key, () => s);
      }
    }
    return out.values.toList()..sort((a, b) {
      final c = a.path.compareTo(b.path);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });
  }

  /// Every subtype of [type], transitively, within the workspace.
  Future<List<InterfaceElement>> subtypes(InterfaceElement type) async {
    final out = <InterfaceElement>[];
    final seen = <String>{};
    final queue = [type];
    while (queue.isNotEmpty && out.length < 500) {
      final t = queue.removeLast();
      for (final s in await analysis.directSubtypes(t)) {
        final key =
            '${s.firstFragment.libraryFragment.source.fullName}#${s.name}';
        if (seen.add(key)) {
          out.add(s);
          queue.add(s);
        }
      }
    }
    return out;
  }

  /// Instance members named like [member] across its class hierarchy: the
  /// members it overrides, the ones overriding it, and their siblings
  /// through shared supertypes. Renaming one means renaming all.
  Future<List<Element>> hierarchyMembers(Element member) async {
    final owner = member.enclosingElement;
    final name = member.name;
    if (owner is! InterfaceElement || name == null || _isStatic(member)) {
      return [member];
    }
    final classes = <InterfaceElement>{owner};
    for (final t in owner.allSupertypes) {
      classes.add(t.element);
    }
    for (final c in classes.toList()) {
      if (!analysis.isAnalyzed(
        c.firstFragment.libraryFragment.source.fullName,
      )) {
        continue;
      }
      classes.addAll(await subtypes(c));
    }
    final out = <Element>{};
    for (final c in classes) {
      for (final m in [...c.fields, ...c.getters, ...c.setters, ...c.methods]) {
        if (m.name == name && !_isStatic(m)) out.add(m.nonSynthetic);
      }
    }
    return out.toList();
  }

  bool _isStatic(Element e) =>
      (e is ExecutableElement && e.isStatic) ||
      (e is FieldElement && e.isStatic);

  Future<Result> refs(String query) async {
    final r = Result('refs')..json['query'] = query;
    final targets = await _resolve(query, r);
    if (targets == null) return r;
    final t = targets.single;
    final sites = await sitesOf(t.element);
    final files = sites.map((s) => s.path).toSet();
    final testFiles = files
        .where((p) => isTestPath(workspace.relative(p)))
        .length;
    r.header(
      'refs ${t.qualified} (${t.kind}, ${t.location}): '
      '${plural(sites.length, 'use')} in ${plural(files.length, 'file')}'
      '${testFiles > 0 ? ' ($testFiles in tests)' : ''}',
    );
    if (sites.isEmpty) {
      r.footer('no uses in ${plural(analysis.fileCount, 'analyzed file')}');
    }
    _siteSections(r, sites);
    r.json['target'] = _targetJson(t);
    return r;
  }

  void _siteSections(Result r, List<Site> sites) {
    final byRole = <(bool, String), List<Site>>{};
    final roles = <String, String>{};
    for (final s in sites) {
      final role = roleOf(s, sources);
      roles[s.key] = role;
      final test = isTestPath(workspace.relative(s.path));
      (byRole[(test, role)] ??= []).add(s);
    }
    final keys = byRole.keys.toList()
      ..sort((a, b) {
        if (a.$1 != b.$1) return a.$1 ? 1 : -1;
        return roleRank(a.$2).compareTo(roleRank(b.$2));
      });
    for (final k in keys) {
      final list = byRole[k]!;
      r.section('${k.$1 ? 'tests, ' : ''}${k.$2} (${list.length}):');
      for (final s in list) {
        final rel = workspace.relative(s.path);
        final line = sources.lineOf(s.path, s.offset);
        r.row('  $rel:$line  ${_clip(sources.lineText(s.path, line))}');
      }
    }
    r.json['uses'] = [
      for (final s in sites)
        {
          'path': workspace.relative(s.path),
          'line': sources.lineOf(s.path, s.offset),
          'role': roles[s.key],
        },
    ];
  }

  Future<Result> showSymbol(String query) async {
    final r = Result('show')..json['query'] = query;
    final targets = await _resolve(query, r);
    if (targets == null) return r;
    final t = targets.single;
    final e = t.element;
    final outline = outlines();
    final decl = outline.files[t.path]?.decls.firstWhere(
      (d) => d.line == t.line && d.name == e.displayName,
      orElse: () => Decl(
        name: e.displayName,
        kind: t.kind,
        line: t.line,
        offset: t.offset,
        end: t.offset,
        sig: e.displayName,
      ),
    );
    r.header('${t.kind} ${t.qualified}  ${t.location}');
    r.header('  ${decl!.sig}');
    if (decl.doc != null) r.header('  ${decl.doc}');
    r.json['target'] = _targetJson(t);

    if (e is InterfaceElement) {
      final supers = [
        for (final s in e.allSupertypes)
          if (!(s.element.name == 'Object' && s.element.library.isDartCore))
            s.getDisplayString(),
      ];
      if (supers.isNotEmpty) r.header('supertypes: ${supers.join(', ')}');
      final subs = await subtypes(e);
      r.section('subtypes (${subs.length}, transitive):');
      for (final s in subs) {
        final st = targetOf(analysis, s)!;
        r.row('  ${st.kind} ${st.qualified}  ${st.location}');
      }
      r.json['subtypes'] = [
        for (final s in subs) _targetJson(targetOf(analysis, s)!),
      ];
      final members = outline.files[t.path]!.decls
          .where((d) => d.owner == e.displayName)
          .toList();
      if (members.isNotEmpty) {
        r.section('members:');
        for (final m in members) {
          r.row('  ${m.line}: ${m.sig}');
        }
      }
    }

    if (e.enclosingElement is InterfaceElement && e is! ConstructorElement) {
      final family = await hierarchyMembers(e);
      final others = [
        for (final m in family)
          if (m != e && m.nonSynthetic != e.nonSynthetic) targetOf(analysis, m),
      ].whereType<Target>().toList();
      if (others.isNotEmpty) {
        r.section(
          'same member elsewhere in the hierarchy (overrides and overridden):',
        );
        for (final o in others) {
          r.row('  ${o.qualified}  ${o.location}');
        }
      }
    }

    final sites = await sitesOf(e);
    final counts = <String, int>{};
    for (final s in sites) {
      final role = roleOf(s, sources);
      counts[role] = (counts[role] ?? 0) + 1;
    }
    final files = sites.map((s) => s.path).toSet();
    final summary =
        (counts.entries.toList()
              ..sort((a, b) => roleRank(a.key).compareTo(roleRank(b.key))))
            .map((e) => '${e.key} ${e.value}')
            .join(', ');
    r.footer(
      'uses: ${plural(sites.length, 'use')} in '
      '${plural(files.length, 'file')}${summary.isEmpty ? '' : ' ($summary)'}',
    );
    if (sites.isNotEmpty)
      r.footer('every use with its line: codegraph refs $query');
    r.json['useCounts'] = counts;

    if (isProvider(e)) {
      final byRole = <String, List<Site>>{};
      for (final s in sites) {
        (byRole[roleOf(s, sources)] ??= []).add(s);
      }
      for (final role
          in byRole.keys.toList()
            ..sort((a, b) => roleRank(a).compareTo(roleRank(b)))) {
        final list = byRole[role]!;
        final lib = list
            .where((s) => !isTestPath(workspace.relative(s.path)))
            .toList();
        if (lib.isEmpty) continue;
        r.section('$role (${lib.length} outside tests):');
        for (final s in lib) {
          r.row(
            '  ${workspace.relative(s.path)}:${sources.lineOf(s.path, s.offset)}',
          );
        }
      }
    }
    return r;
  }

  Future<Result> impact(String query, {bool diff = false, String? base}) async {
    final r = Result('impact')..json['query'] = diff ? '--diff' : query;
    final outline = outlines();
    final seeds = <Target>[];
    final notes = <String>[];

    if (diff) {
      final changes = gitChanges(workspace, base: base);
      if (changes == null) {
        r.exit = Exit.failed;
        r.header('not a git repository, or `git diff` failed');
        return r;
      }
      r.header(
        'impact of ${plural(changes.length, 'changed Dart file')}'
        '${base == null ? ' in the working tree' : ' since $base'}',
      );
      for (final c in changes) {
        if (c.deleted) {
          final importers = outline.importers(c.path);
          notes.add(
            'deleted ${c.path}${importers.isEmpty ? '' : ', still imported by ${importers.length}: ${importers.take(5).join(', ')}'}',
          );
          continue;
        }
        final f = outline.files[c.path];
        if (f == null) {
          notes.add('${c.path} is not analyzed');
          continue;
        }
        final touched = <Decl>{};
        for (final h in c.hunks) {
          for (final d in f.decls) {
            final start = sources.lineOf(workspace.absolute(c.path), d.offset);
            final end = sources.lineOf(workspace.absolute(c.path), d.end);
            if (h.start <= end && start <= h.end) touched.add(d);
          }
        }
        final innermost = touched
            .where(
              (d) => !touched.any(
                (o) =>
                    o != d &&
                    o.offset >= d.offset &&
                    o.end <= d.end &&
                    o.offset != d.offset,
              ),
            )
            .toList();
        if (innermost.isEmpty && c.hunks.isNotEmpty) {
          notes.add(
            '${c.path}: changes outside any declaration (directives or top of file)',
          );
        }
        for (final d in innermost) {
          final found = await lookup(analysis, outline, '${c.path}:${d.line}');
          if (found is Found) seeds.addAll(found.targets);
        }
      }
    } else {
      final file = fileCandidates(outline, query);
      if (query.endsWith('.dart') ||
          (file.length == 1 && !RegExp(r'^\w+$').hasMatch(query))) {
        if (file.length != 1) {
          r.exit = file.isEmpty ? Exit.failed : Exit.ambiguous;
          r.header(
            file.isEmpty
                ? 'no analyzed file matches "$query"'
                : '"$query" matches ${plural(file.length, 'file')}:',
          );
          for (final p in file.take(20)) {
            r.row('  $p');
          }
          return r;
        }
        r.header('impact of ${file.single}');
        for (final d in outline.files[file.single]!.topLevel) {
          final found = await lookup(
            analysis,
            outline,
            '${file.single}:${d.line}',
          );
          if (found is Found) seeds.addAll(found.targets);
        }
      } else {
        final targets = await _resolve(query, r);
        if (targets == null) return r;
        seeds.addAll(targets);
        r.header(
          'impact of ${seeds.single.kind} ${seeds.single.qualified} (${seeds.single.location})',
        );
      }
    }

    final seedKeys = {for (final s in seeds) '${s.path}:${s.offset}'};
    final direct = <String, Set<String>>{};
    final dependents = <String, Target>{};
    var directSites = 0;
    for (final s in seeds) {
      final sites = await sitesOf(s.element);
      directSites += sites.length;
      for (final site in sites) {
        final rel = workspace.relative(site.path);
        (direct[rel] ??= {}).add(s.qualified);
        final enclosing = outline.files[rel]?.enclosing(site.offset);
        if (enclosing == null) continue;
        final key = '$rel:${enclosing.line}:${enclosing.qualified}';
        if (dependents.containsKey(key)) continue;
        final found = await lookup(analysis, outline, '$rel:${enclosing.line}');
        if (found is Found) {
          for (final t in found.targets) {
            if (!seedKeys.contains('${t.path}:${t.offset}'))
              dependents[key] = t;
          }
        }
      }
      if (s.element is InterfaceElement) {
        for (final sub in await subtypes(s.element as InterfaceElement)) {
          final t = targetOf(analysis, sub)!;
          dependents['${t.path}:${t.line}:${t.qualified}'] = t;
        }
      }
    }

    const depthTwoCap = 40;
    final second = <String, Set<String>>{};
    var capped = false;
    var visited = 0;
    for (final d in dependents.values) {
      if (visited++ >= depthTwoCap) {
        capped = true;
        break;
      }
      for (final site in await sitesOf(d.element)) {
        final rel = workspace.relative(site.path);
        if (direct.containsKey(rel)) continue;
        (second[rel] ??= {}).add(d.qualified);
      }
    }

    final seedFiles = {for (final s in seeds) s.path};
    final allFiles = {...direct.keys, ...second.keys}..removeAll(seedFiles);
    final tests = allFiles.where(isTestPath).toList()..sort();
    final libFiles = allFiles.where((p) => !isTestPath(p)).toList();
    r.header(
      '${plural(seeds.length, 'declaration')}${diff ? ' changed' : ''}; '
      '${plural(directSites, 'direct use')}; '
      '${plural(libFiles.length, 'file')} outside tests and '
      '${plural(tests.length, 'test file')} reached within two steps',
    );
    for (final n in notes) {
      r.header('  $n');
    }

    final directLib =
        direct.keys
            .where((p) => !isTestPath(p) && !seedFiles.contains(p))
            .toList()
          ..sort();
    r.section('uses it directly (${directLib.length}):');
    for (final p in directLib) {
      r.row('  $p  (${direct[p]!.take(3).join(', ')})');
    }
    final secondLib =
        second.keys
            .where((p) => !isTestPath(p) && !seedFiles.contains(p))
            .toList()
          ..sort();
    r.section('one step further (${secondLib.length}):');
    for (final p in secondLib) {
      r.row('  $p  (via ${second[p]!.take(3).join(', ')})');
    }
    r.section('tests that reference it within two steps (${tests.length}):');
    for (final p in tests) {
      r.row('  $p');
    }
    final publishable = workspace
        .publishablePackageRoots()
        .map(workspace.relative)
        .where((pkg) => allFiles.any((f) => f.startsWith('$pkg/')))
        .toList();
    if (publishable.isNotEmpty) {
      r.footer('crosses publishable packages: ${publishable.join(', ')}');
    }
    if (capped)
      r.partial(
        'second step limited to the first $depthTwoCap dependents of ${dependents.length}',
      );
    r.json['seeds'] = [for (final s in seeds) _targetJson(s)];
    r.json['direct'] = {
      for (final p in direct.keys.toList()..sort()) p: direct[p]!.toList(),
    };
    r.json['secondStep'] = {
      for (final p in second.keys.toList()..sort()) p: second[p]!.toList(),
    };
    r.json['tests'] = tests;
    return r;
  }

  /// Resolves [query] to exactly one target, or fills [r] with why not.
  Future<List<Target>?> _resolve(String query, Result r) async {
    final found = await lookup(analysis, outlines(), query);
    if (found is NotFound) {
      r.exit = Exit.failed;
      r.header(found.message);
      r.footer('try: codegraph find $query');
      return null;
    }
    final targets = (found as Found).targets;
    if (targets.length > 1) {
      r.exit = Exit.ambiguous;
      r.header(
        '"$query" matches ${plural(targets.length, 'declaration')}; '
        'name one by path:line or Owner.member:',
      );
      for (final t in targets) {
        r.row('  ${t.kind} ${t.qualified}  ${t.location}');
      }
      r.json['candidates'] = [for (final t in targets) _targetJson(t)];
      return null;
    }
    return targets;
  }

  Map<String, Object?> _targetJson(Target t) => {
    'name': t.qualified,
    'kind': t.kind,
    'path': t.path,
    'line': t.line,
  };
}

String _clip(String s) => s.length <= 110 ? s : '${s.substring(0, 107)}...';
