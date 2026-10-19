// The only file that touches `package:analyzer/src/`. Everything that changes
// when the analyzer is upgraded should change here.
import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
// ignore_for_file: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/search.dart' as search;

import 'sdk.dart';
import 'workspace.dart';

/// One use of an element: a span in an analyzed file. Paths outside this
/// file are always workspace-relative.
class Site {
  Site(this.path, this.offset, this.length, this.kind, this.enclosing);

  final String path;
  final int offset;
  final int length;

  /// The analyzer's own classification (`READ`, `WRITE`, `INVOCATION`,
  /// `REFERENCE`, `REFERENCE_BY_NAMED_ARGUMENT`, ...).
  final String kind;

  /// The innermost element whose declaration holds the use.
  final Element enclosing;

  String get key => '$path:$offset:$length';
}

/// Where an element is declared.
class Location {
  Location(this.path, this.offset, this.line);

  /// Workspace-relative.
  final String path;
  final int offset;
  final int line;
}

typedef Progress = void Function(String message);

/// The newest Dart language version the bundled analyzer understands.
String analyzerLanguageVersion() {
  final v = ExperimentStatus.currentVersion;
  return '${v.major}.${v.minor}';
}

class Analysis {
  Analysis._(this.workspace, this._collection, this._drivers, this.fineDeps);

  final Workspace workspace;
  final AnalysisContextCollectionImpl _collection;
  final List<AnalysisDriver> _drivers;
  final bool fineDeps;

  final Map<String, AnalysisDriver> _owner = {};
  final Map<String, _Stamp> _stamps = {};
  final Map<String, _Stamp> _configStamps = {};
  final Map<String, _Stamp> _dirStamps = {};

  int _indexed = 0;
  bool _warm = false;
  Future<void>? _warming;

  bool get warm => _warm;
  int get fileCount => _owner.length;
  int get contextCount => _drivers.length;
  int get indexedCount => _indexed;

  /// Every analyzed file, workspace-relative.
  Iterable<String> get files => _owner.keys.map(workspace.relative);

  static String byteStoreBase() {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Platform.environment['CODEGRAPH_BYTE_STORE'] ??
        '$home/.cache/codegraph/byte-store';
  }

  /// One cache per checkout. Entries are keyed by content, but some carry
  /// paths, so a cache filled by a checkout at another path silently drops
  /// references here.
  static String byteStoreFor(Workspace workspace) {
    var h = 0xcbf29ce484222325;
    for (final c in workspace.root.codeUnits) {
      h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return '${byteStoreBase()}/${h.toRadixString(16)}';
  }

  /// Deletes per-checkout caches untouched for [age], keeping disk use bounded.
  static void pruneByteStores({Duration age = const Duration(days: 30)}) {
    final base = Directory(byteStoreBase());
    if (!base.existsSync()) return;
    final cutoff = DateTime.now().subtract(age);
    for (final d in base.listSync().whereType<Directory>()) {
      try {
        final marker = File('${d.path}/.last-used');
        final used = marker.existsSync()
            ? marker.lastModifiedSync()
            : d.statSync().modified;
        if (used.isBefore(cutoff)) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static Future<Analysis> open(
    Workspace workspace, {
    bool fineDeps = false,
    String? byteStore,
  }) async {
    final storePath = byteStore ?? byteStoreFor(workspace);
    // FileByteStore writes nothing, silently, when its directory is missing.
    Directory(storePath).createSync(recursive: true);
    File('$storePath/.last-used').writeAsStringSync(workspace.root);
    final collection = AnalysisContextCollectionImpl(
      includedPaths: [workspace.root],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: sdkPathForAnalysis(),
      byteStore: FileByteStore(storePath),
      enableIndex: true,
      withFineDependencies: fineDeps,
    );
    final drivers = [for (final c in collection.contexts) c.driver];
    final analysis = Analysis._(workspace, collection, drivers, fineDeps);
    analysis._stampConfig();
    await analysis.sync();
    return analysis;
  }

  /// Brings the analyzer in line with the disk: new, changed and deleted
  /// files. Returns the workspace-relative paths that changed. A stat per known file and per
  /// directory holding one; the context roots are only re-walked when a
  /// directory changed, because a new or deleted file changes its parent.
  Future<List<String>> sync() async {
    final changed = <String>[];
    var rescan = _dirStamps.isEmpty;
    if (!rescan) {
      for (final e in _dirStamps.entries) {
        if (_Stamp.ofDir(e.key) != e.value) {
          rescan = true;
          break;
        }
      }
    }
    if (rescan) {
      final seen = <String>{};
      _dirStamps.clear();
      for (final context in _collection.contexts) {
        final driver = context.driver;
        for (final raw in context.contextRoot.analyzedFiles()) {
          if (!raw.endsWith('.dart')) continue;
          final path = workspace.absolute(raw);
          seen.add(path);
          final dir = path.substring(0, path.lastIndexOf('/'));
          _dirStamps.putIfAbsent(dir, () => _Stamp.ofDir(dir));
          if (!_owner.containsKey(path)) {
            driver.addFile(path);
            _owner[path] = driver;
            _stamps[path] = _Stamp.of(path);
            if (_warm) changed.add(path);
          }
        }
      }
      for (final path in _owner.keys.toList()) {
        if (seen.contains(path)) continue;
        _owner.remove(path)!.removeFile(path);
        _stamps.remove(path);
        changed.add(path);
      }
    }
    for (final e in _owner.entries) {
      final stamp = _Stamp.of(e.key);
      if (_stamps[e.key] != stamp) {
        e.value.changeFile(e.key);
        _stamps[e.key] = stamp;
        if (!changed.contains(e.key)) changed.add(e.key);
      }
    }
    for (final d in _drivers) {
      await d.applyPendingFileChanges();
    }
    return [for (final p in changed) workspace.relative(p)];
  }

  /// Tells the analyzer about files this process just wrote.
  Future<void> notifyChanged(Iterable<String> relativePaths) async {
    for (final p in relativePaths) {
      final path = workspace.absolute(p);
      final driver = _owner[path];
      if (driver == null) continue;
      driver.changeFile(path);
      _stamps[path] = _Stamp.of(path);
    }
    for (final d in _drivers) {
      await d.applyPendingFileChanges();
    }
  }

  /// True when a pubspec, analysis_options or package config changed since
  /// the contexts were built. The caller must reopen.
  bool get configChanged {
    for (final e in _configStamps.entries) {
      if (_Stamp.of(e.key) != e.value) return true;
    }
    return false;
  }

  void _stampConfig() {
    for (final f in workspace.configFiles()) {
      _configStamps[f] = _Stamp.of(f);
    }
  }

  /// Indexes every analyzed file. Searches are complete without this (they
  /// index what they need), but a warm index answers in milliseconds.
  Future<void> warmUp({Progress? progress}) {
    return _warming ??= () async {
      final paths = _owner.keys.toList()..sort();
      _indexed = 0;
      var last = DateTime.now();
      await Future.wait([
        for (final p in paths)
          _owner[p]!.getIndex(p).then((_) {
            _indexed++;
            final now = DateTime.now();
            if (progress != null &&
                now.difference(last) > const Duration(seconds: 2)) {
              last = now;
              progress('indexing workspace: $_indexed/${paths.length} files');
            }
          }),
      ]);
      _warm = true;
    }();
  }

  bool isAnalyzed(String relativePath) =>
      _owner.containsKey(workspace.absolute(relativePath));

  /// Where [element] is declared, or null when that is outside the analyzed
  /// workspace (the SDK, a pub package, an excluded directory).
  Location? locate(Element element) {
    final fragment = element.nonSynthetic.firstFragment;
    final lib = fragment.libraryFragment;
    if (lib == null || !_owner.containsKey(lib.source.fullName)) return null;
    final offset = fragment.nameOffset ?? fragment.offset;
    return Location(
      workspace.relative(lib.source.fullName),
      offset,
      lib.lineInfo.getLocation(offset).lineNumber,
    );
  }

  /// The URI of the library declaring [element], for messages about
  /// declarations outside the workspace.
  String sourceOf(Element element) =>
      '${element.nonSynthetic.firstFragment.libraryFragment?.source.uri ?? 'unknown'}';

  Future<ResolvedLibraryResult?> library(String path) async {
    final abs = workspace.absolute(path);
    final driver = _owner[abs] ?? _contextDriver(abs);
    if (driver == null) return null;
    final r = await driver.getResolvedLibrary(abs);
    return r is ResolvedLibraryResult ? r : null;
  }

  Future<ResolvedUnitResult?> unit(String path) async {
    final abs = workspace.absolute(path);
    final driver = _owner[abs] ?? _contextDriver(abs);
    if (driver == null) return null;
    final r = await driver.getResolvedUnit(abs);
    return r is ResolvedUnitResult ? r : null;
  }

  AnalysisDriver? _contextDriver(String abs) {
    try {
      return _collection.contextFor(abs).driver;
    } catch (_) {
      return null;
    }
  }

  /// Every use of [element] across every context, deduplicated, restricted
  /// to analyzed files.
  Future<List<Site>> references(Element element) async {
    final out = <String, Site>{};
    for (final d in _drivers) {
      for (final r in await d.search.references(element)) {
        final site = _site(r);
        if (site != null) out.putIfAbsent(site.key, () => site);
      }
    }
    return _sorted(out.values);
  }

  /// Uses of a member name whose receiver the analyzer could not resolve:
  /// dynamic calls, and calls on types that do not declare it.
  Future<List<Site>> unresolvedMemberReferences(String name) async {
    final out = <String, Site>{};
    for (final d in _drivers) {
      for (final r in await d.search.unresolvedMemberReferences(name)) {
        final site = _site(r);
        if (site != null) out.putIfAbsent(site.key, () => site);
      }
    }
    return _sorted(out.values);
  }

  /// Direct subtypes of [type]: classes, mixins, enums and extension types
  /// that extend, implement, mix in, or constrain it.
  Future<List<InterfaceElement>> directSubtypes(InterfaceElement type) async {
    final out = <String, InterfaceElement>{};
    for (final d in _drivers) {
      for (final r in await d.search.directSubtypeReferences(type)) {
        final e = r.enclosingFragment.element;
        if (e is! InterfaceElement) continue;
        final at = locate(e);
        if (at == null) continue;
        out.putIfAbsent('${at.path}#${e.name}', () => e);
      }
    }
    return out.values.toList()
      ..sort((a, b) => '${a.name}'.compareTo('${b.name}'));
  }

  /// Members named [name] in any class, mixin, enum or extension.
  Future<List<Element>> classMembers(String name) async {
    final out = <String, Element>{};
    for (final d in _drivers) {
      for (final e in await d.search.classMembers(name)) {
        final at = locate(e);
        if (at == null) continue;
        out.putIfAbsent('${at.path}:${at.offset}', () => e);
      }
    }
    return out.values.toList();
  }

  /// Top-level declarations whose name matches [pattern].
  Future<List<Element>> topLevelElements(RegExp pattern) async {
    final out = <String, Element>{};
    for (final d in _drivers) {
      for (final e in await d.search.topLevelElements(pattern)) {
        final at = locate(e);
        if (at == null) continue;
        out.putIfAbsent('${at.path}:${at.offset}', () => e);
      }
    }
    return out.values.toList();
  }

  /// Error-severity diagnostics in [path].
  Future<List<Diagnostic>> errors(String path) async {
    final abs = workspace.absolute(path);
    final driver = _owner[abs];
    if (driver == null) return const [];
    final r = await driver.getErrors(abs);
    if (r is! ErrorsResult) return const [];
    return [
      for (final d in r.diagnostics)
        if (d.diagnosticCode.severity == DiagnosticSeverity.ERROR) d,
    ];
  }

  Site? _site(search.SearchResult r) {
    final path = r.enclosingFragment.libraryFragment?.source.fullName;
    if (path == null || !_owner.containsKey(path)) return null;
    return Site(
      workspace.relative(path),
      r.offset,
      r.length,
      r.kind.name,
      r.enclosingFragment.element,
    );
  }

  List<Site> _sorted(Iterable<Site> sites) => sites.toList()
    ..sort((a, b) {
      final c = a.path.compareTo(b.path);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });

  Future<void> dispose() => _collection.dispose();
}

class _Stamp {
  const _Stamp(this.modified, this.size);

  factory _Stamp.of(String path) {
    final s = FileStat.statSync(path);
    if (s.type == FileSystemEntityType.notFound) return const _Stamp(-1, -1);
    return _Stamp(s.modified.microsecondsSinceEpoch, s.size);
  }

  factory _Stamp.ofDir(String path) {
    final s = FileStat.statSync(path);
    if (s.type == FileSystemEntityType.notFound) return const _Stamp(-1, -1);
    return _Stamp(s.modified.microsecondsSinceEpoch, 0);
  }

  final int modified;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is _Stamp && other.modified == modified && other.size == size;

  @override
  int get hashCode => Object.hash(modified, size);
}
