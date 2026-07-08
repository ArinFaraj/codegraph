// Reachability-gated name resolution shared by provider wiring, type edges,
// and navigation page-file resolution. One BFS implementation, one ambiguity
// doctrine: resolve when unique or reachability narrows to exactly one; refuse
// otherwise — never first-wins.

class ProviderDecl {
  ProviderDecl(this.name, this.file, this.kind, this.autoDispose, this.line);
  final String name;
  final String file;
  final String kind;
  final bool autoDispose;
  final int line;
}

class ClassDecl {
  ClassDecl(this.name, this.file, this.supertypes);
  final String name;
  final String file;
  final List<String> supertypes; // extends + implements names (cleaned)
}

/// Transitive import/export/part reachability from each lib file.
class Reachability {
  Reachability(Map<String, List<String>> importGraph)
      : _importGraph = importGraph;

  Reachability.fromFiles(
      Iterable<({String libPath, List<String> imports})> files)
      : _importGraph = {for (final f in files) f.libPath: f.imports};

  final Map<String, List<String>> _importGraph;
  final Map<String, Set<String>> _cache = {};

  Set<String> from(String start) => _cache.putIfAbsent(start, () {
        final seen = <String>{start};
        final queue = <String>[start];
        while (queue.isNotEmpty) {
          final cur = queue.removeLast();
          for (final next in _importGraph[cur] ?? const <String>[]) {
            if (seen.add(next)) queue.add(next);
          }
        }
        return seen;
      });
}

class ProviderResolver {
  ProviderResolver(this.declsByName, this._reach)
      : ambiguousNames = {
          for (final e in declsByName.entries)
            if (e.value.length > 1) e.key,
        };

  final Map<String, List<ProviderDecl>> declsByName;
  final Set<String> ambiguousNames;
  final Reachability _reach;

  String nodeIdFor(ProviderDecl p) => ambiguousNames.contains(p.name)
      ? 'provider:${p.name}@${p.file}'
      : 'provider:${p.name}';

  Map<String, dynamic> edgeFieldsFor(String readerFile, String name) {
    final decls = declsByName[name];
    if (decls == null) return {'dst': 'provider:$name', 'external': true};
    if (!ambiguousNames.contains(name)) {
      return {'dst': nodeIdFor(decls.single)};
    }
    final reach = _reach.from(readerFile);
    final matches = decls.where((d) => reach.contains(d.file)).toList();
    if (matches.length == 1) return {'dst': nodeIdFor(matches.single)};
    return {
      'dst': 'provider:$name',
      'ambiguous': true,
      'candidates': decls.map((d) => d.file).toList(),
    };
  }
}

/// Class/type NAME resolution — same doctrine as [ProviderResolver].
class ClassResolver {
  ClassResolver(Map<String, List<ClassDecl>> declsByName, this._reach)
      : _filesByName = {
          for (final e in declsByName.entries)
            e.key: {for (final c in e.value) c.file},
        },
        ambiguousNames = {
          for (final e in declsByName.entries)
            if ({for (final c in e.value) c.file}.length > 1) e.key,
        };

  final Map<String, Set<String>> _filesByName;
  final Reachability _reach;
  final Set<String> ambiguousNames;

  String? fileFor(String name, String readerFile) {
    final files = _filesByName[name];
    if (files == null || files.isEmpty) return null;
    if (files.length == 1) return files.single;
    final reach = _reach.from(readerFile);
    final reachable = files.where(reach.contains).toList();
    return reachable.length == 1 ? reachable.single : null;
  }

  List<String> filesOf(String name) =>
      (_filesByName[name]?.toList() ?? <String>[])..sort();

  /// Edge fields for an `implements/extends` supertype reference from
  /// [readerFile]: resolved file, ambiguous refusal, or external bare type.
  Map<String, dynamic> typeEdgeFieldsFor(String readerFile, String name) {
    final file = fileFor(name, readerFile);
    if (file != null) return {'dst': 'file:$file'};
    if (ambiguousNames.contains(name)) {
      return {
        'dst': 'type:$name',
        'ambiguous': true,
        'candidates': filesOf(name),
      };
    }
    return {'dst': 'type:$name'};
  }
}
