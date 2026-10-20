// The only file that touches `package:analyzer/src/`. Everything that changes
// when the analyzer is upgraded should change here.
import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_options.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/error_processor.dart';
import 'package:analyzer/source/file_source.dart';
import 'package:analyzer/source/line_info.dart';
// ignore_for_file: implementation_imports
import 'package:analyzer/src/analysis_options/analysis_options.dart'
    show AnalysisOptionsImpl;
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/search.dart' as search;
import 'package:analyzer/src/pubspec/pubspec_validator.dart';
import 'package:yaml/yaml.dart';

import 'byte_store.dart';
import 'files.dart';
import 'sdk.dart';
import 'workspace.dart';

/// One use of an element: a span in an analyzed file. Paths outside this
/// file are always workspace-relative.
class Site {
  Site(this.path, this.offset, this.length, this.kind);

  final String path;
  final int offset;
  final int length;

  /// The analyzer's own classification (`READ`, `WRITE`, `INVOCATION`,
  /// `REFERENCE`, `REFERENCE_BY_NAMED_ARGUMENT`, ...).
  final String kind;

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

/// A diagnostic as `dart analyze` reports it: after the analysis options of
/// its file have raised, lowered or silenced it.
class Problem {
  Problem(
    this.path,
    this.offset,
    this.line,
    this.column,
    this.severity,
    this.code,
    this.message,
  );

  /// Workspace-relative.
  final String path;
  final int offset;
  final int line;
  final int column;

  /// `error`, `warning` or `info`.
  final String severity;
  final String code;
  final String message;

  bool get isError => severity == 'error';

  /// What identifies a problem across edits that move it to another line.
  String get identity => '$severity|$code|$message';

  Map<String, Object?> toJson() => {
    'path': path,
    'line': line,
    'column': column,
    'severity': severity,
    'code': code,
    'message': message,
  };
}

typedef Progress = void Function(String message);

/// The newest Dart language version the bundled analyzer understands.
String analyzerLanguageVersion() {
  final v = ExperimentStatus.currentVersion;
  return '${v.major}.${v.minor}';
}

class Analysis {
  Analysis._(this.workspace, this._collection, this.fineDeps)
    : _tracker = FileTracker(workspace);

  final Workspace workspace;
  final AnalysisContextCollectionImpl _collection;
  final bool fineDeps;
  final FileTracker _tracker;

  /// Workspace-relative path to the driver analyzing it.
  final Map<String, AnalysisDriver> _owner = {};

  int _indexed = 0;
  Future<void>? _warming;

  int get fileCount => _owner.length;
  int get indexedCount => _indexed;

  /// Every analyzed file, workspace-relative.
  Iterable<String> get files => _owner.keys;

  Iterable<AnalysisDriver> get _drivers =>
      _collection.contexts.map((c) => c.driver);

  static Future<Analysis> open(
    Workspace workspace, {
    bool fineDeps = false,
    String? byteStore,
  }) async {
    final storePath = byteStore ?? byteStoreFor(workspace);
    final collection = AnalysisContextCollectionImpl(
      includedPaths: [workspace.root],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: sdkPathForAnalysis(),
      byteStore: FileByteStore(openByteStore(storePath, workspace)),
      enableIndex: true,
      withFineDependencies: fineDeps,
    );
    final analysis = Analysis._(workspace, collection, fineDeps);
    await analysis.sync();
    return analysis;
  }

  /// Brings the analyzer in line with the disk and says what changed.
  Future<FileDelta> sync() async {
    final delta = _tracker.sync();
    for (final rel in delta.added) {
      final abs = workspace.absolute(rel);
      final driver = _collection.contextFor(abs).driver;
      driver.addFile(abs);
      _owner[rel] = driver;
    }
    for (final rel in delta.changed) {
      _owner[rel]?.changeFile(workspace.absolute(rel));
    }
    for (final rel in delta.removed) {
      _owner.remove(rel)?.removeFile(workspace.absolute(rel));
    }
    for (final d in _drivers) {
      await d.applyPendingFileChanges();
    }
    return delta;
  }

  /// Tells the analyzer about files this process just wrote.
  Future<void> notifyChanged(Iterable<String> paths) async {
    final list = paths.toList();
    for (final rel in list) {
      _owner[rel]?.changeFile(workspace.absolute(rel));
    }
    _tracker.restamp(list);
    for (final d in _drivers) {
      await d.applyPendingFileChanges();
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
          _owner[p]!.getIndex(workspace.absolute(p)).then((_) {
            _indexed++;
            final now = DateTime.now();
            if (progress != null &&
                now.difference(last) > const Duration(seconds: 2)) {
              last = now;
              progress('indexing workspace: $_indexed/${paths.length} files');
            }
          }),
      ]);
    }();
  }

  bool isAnalyzed(String path) => _owner.containsKey(path);

  /// Analyzed files last modified at or after [t], as of the last [sync].
  List<String> modifiedSince(DateTime t) => _tracker.modifiedSince(t);

  /// The workspace-relative path of an analyzer source, when it is analyzed.
  String? _analyzedPath(String fullName) {
    final rel = workspace.relativeOrNull(fullName);
    return rel != null && _owner.containsKey(rel) ? rel : null;
  }

  /// Where [element] is declared, or null when that is outside the analyzed
  /// workspace (the SDK, a pub package, an excluded directory).
  Location? locate(Element element) {
    final fragment = element.nonSynthetic.firstFragment;
    final lib = fragment.libraryFragment;
    final path = lib == null ? null : _analyzedPath(lib.source.fullName);
    if (lib == null || path == null) return null;
    final offset = fragment.nameOffset ?? fragment.offset;
    return Location(path, offset, lib.lineInfo.getLocation(offset).lineNumber);
  }

  /// The URI of the library declaring [element], for messages about
  /// declarations outside the workspace.
  String sourceOf(Element element) =>
      '${element.nonSynthetic.firstFragment.libraryFragment?.source.uri ?? 'unknown'}';

  Future<ResolvedLibraryResult?> library(String path) async {
    final r = await _driverFor(
      path,
    )?.getResolvedLibrary(workspace.absolute(path));
    return r is ResolvedLibraryResult ? r : null;
  }

  Future<ResolvedUnitResult?> unit(String path) async {
    final r = await _driverFor(path)?.getResolvedUnit(workspace.absolute(path));
    return r is ResolvedUnitResult ? r : null;
  }

  AnalysisDriver? _driverFor(String path) => _owner[path];

  /// Every use of [element] across every context, deduplicated, restricted
  /// to analyzed files.
  Future<List<Site>> references(Element element) =>
      _sites((s) => s.references(element));

  /// Uses of a member name whose receiver the analyzer could not resolve:
  /// dynamic calls, and calls on types that do not declare it.
  Future<List<Site>> unresolvedMemberReferences(String name) =>
      _sites((s) => s.unresolvedMemberReferences(name));

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
  Future<List<Element>> classMembers(String name) =>
      _elements((s) => s.classMembers(name));

  /// Top-level declarations whose name matches [pattern].
  Future<List<Element>> topLevelElements(RegExp pattern) =>
      _elements((s) => s.topLevelElements(pattern));

  /// [search] run in every context, as use sites in analyzed files,
  /// deduplicated and sorted.
  Future<List<Site>> _sites(
    Future<List<search.SearchResult>> Function(search.Search) search,
  ) async {
    final out = <String, Site>{};
    for (final d in _drivers) {
      for (final r in await search(d.search)) {
        if (_site(r) case final site?) out.putIfAbsent(site.key, () => site);
      }
    }
    return _sorted(out.values);
  }

  /// [search] run in every context, keeping elements declared in analyzed
  /// files, once each.
  Future<List<Element>> _elements(
    Future<Iterable<Element>> Function(search.Search) search,
  ) async {
    final out = <String, Element>{};
    for (final d in _drivers) {
      for (final e in await search(d.search)) {
        if (locate(e) case final at?) {
          out.putIfAbsent('${at.path}:${at.offset}', () => e);
        }
      }
    }
    return out.values.toList();
  }

  /// Error-severity problems in [path].
  Future<List<Problem>> errors(String path) async => [
    for (final p in await problems(path))
      if (p.isError) p,
  ];

  /// What `dart analyze` reports for [path]: the analyzer's diagnostics with
  /// TODOs dropped and the `errors:` settings of the file's own analysis
  /// options applied.
  Future<List<Problem>> problems(String path) async {
    final driver = _owner[path];
    if (driver == null) return const [];
    final abs = workspace.absolute(path);
    final r = await driver.getErrors(abs);
    if (r is! ErrorsResult) return const [];
    return _processed(path, abs, r.diagnostics, r.lineInfo);
  }

  /// What the pubspec validator reports for a `pubspec.yaml`: missing assets,
  /// bad dependency entries and the like.
  List<Problem> pubspecProblems(String path) {
    final abs = workspace.absolute(path);
    final file = PhysicalResourceProvider.INSTANCE.getFile(abs);
    if (!file.exists) return const [];
    final String text;
    final YamlNode contents;
    try {
      text = file.readAsStringSync();
      contents = loadYamlNode(text, sourceUrl: file.toUri());
    } on Exception {
      return const [];
    }
    final diagnostics = validatePubspec(
      contents: contents,
      source: FileSource(file),
      provider: PhysicalResourceProvider.INSTANCE,
      analysisOptions: _optionsFor(abs),
    );
    return _processed(path, abs, diagnostics, LineInfo.fromContent(text));
  }

  /// Analyzer plugins the workspace root's analysis options enable, with
  /// includes applied. `check` does not run them; `dart analyze` does.
  List<String> analyzerPlugins() {
    final options = _optionsFor('${workspace.root}/pubspec.yaml');
    if (options is! AnalysisOptionsImpl) return const [];
    return {
      for (final c in options.pluginConfigurations)
        if (c.isEnabled) c.name,
      ...options.enabledLegacyPluginNames,
    }.toList();
  }

  AnalysisOptions? _optionsFor(String abs) {
    try {
      return _collection
          .contextFor(abs)
          .getAnalysisOptionsForFile(
            PhysicalResourceProvider.INSTANCE.getFile(abs),
          );
    } on StateError {
      return null;
    }
  }

  List<Problem> _processed(
    String path,
    String abs,
    List<Diagnostic> diagnostics,
    LineInfo lines,
  ) {
    final options = _optionsFor(abs);
    final out = <Problem>[];
    for (final d in diagnostics) {
      if (d.diagnosticCode.type == DiagnosticType.TODO) continue;
      var severity = d.diagnosticCode.severity;
      final processor = ErrorProcessor.getProcessor(options, d);
      if (processor != null) {
        final s = processor.severity;
        if (s == null) continue;
        severity = s;
      }
      final at = lines.getLocation(d.offset);
      out.add(
        Problem(
          path,
          d.offset,
          at.lineNumber,
          at.columnNumber,
          switch (severity) {
            DiagnosticSeverity.ERROR => 'error',
            DiagnosticSeverity.WARNING => 'warning',
            _ => 'info',
          },
          d.diagnosticCode.lowerCaseName,
          d.message,
        ),
      );
    }
    return out..sort((a, b) => a.offset.compareTo(b.offset));
  }

  Site? _site(search.SearchResult r) {
    final fullName = r.enclosingFragment.libraryFragment?.source.fullName;
    final path = fullName == null ? null : _analyzedPath(fullName);
    if (path == null) return null;
    return Site(path, r.offset, r.length, r.kind.name);
  }

  List<Site> _sorted(Iterable<Site> sites) => sites.toList()
    ..sort((a, b) {
      final c = a.path.compareTo(b.path);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });

  Future<void> dispose() => _collection.dispose();
}
