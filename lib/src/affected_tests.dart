// `codegraph affected-tests [paths...] [--base <ref>]` — fail-open test plan.
//
// The planner selects test ENTRYPOINT files, never individual test names. It
// follows the production graph outward from changed libraries, then intersects
// that affected closure with each test entrypoint's local import/helper closure.
// Any evidence gap expands to workspace-wide test commands; uncertainty can
// add work, never remove it.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'cli_util.dart';
import 'freshness.dart';
import 'impact.dart';
import 'model.dart';
import 'refactor_index.dart';

const _testDirs = ['test', 'integration_test', 'patrol_test'];
const _generatedSuffixes = [
  '.g.dart',
  '.freezed.dart',
  '.gr.dart',
  '.gen.dart',
  '.mocks.dart',
  '.config.dart',
];

class ChangedLineRange {
  const ChangedLineRange({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;

  Map<String, dynamic> toJson() => {
        'oldStart': oldStart,
        'oldCount': oldCount,
        'newStart': newStart,
        'newCount': newCount,
      };
}

class ChangedPath {
  const ChangedPath(
    this.status,
    this.path, {
    this.ranges = const [],
    this.rangesKnown = false,
  });
  final String status;
  final String path;
  final List<ChangedLineRange> ranges;
  final bool rangesKnown;

  Map<String, dynamic> toJson() => {
        'status': status,
        'path': path,
        if (rangesKnown)
          'hunks': ranges.map((range) => range.toJson()).toList(),
      };
}

class ChangeAttribution {
  ChangeAttribution(this.path, this.mode, this.symbols, this.fallback);

  final String path;
  final String mode;
  final List<String> symbols;
  final String? fallback;

  Map<String, dynamic> toJson() => {
        'path': path,
        'mode': mode,
        if (symbols.isNotEmpty) 'symbols': symbols,
        if (fallback != null) 'fallback': fallback,
      };
}

class TestSelection {
  TestSelection(this.file, this.packageRoot, this.kind, this.reasons);
  final String file;
  final String packageRoot;
  final String kind;
  final List<String> reasons;

  Map<String, dynamic> toJson() => {
        'file': file,
        'package': packageRoot,
        'kind': kind,
        'reasons': reasons,
      };
}

class TestCommand {
  TestCommand(
    this.workingDirectory,
    this.runner,
    this.kind,
    this.argv, {
    this.requiresDevice = false,
  });
  final String workingDirectory;
  final String runner;
  final String kind;
  final List<String> argv;
  final bool requiresDevice;

  Map<String, dynamic> toJson() => {
        'workingDirectory': workingDirectory,
        'runner': runner,
        'kind': kind,
        'argv': argv,
        if (requiresDevice) 'requiresDevice': true,
      };
}

class AffectedTestPlan {
  AffectedTestPlan({
    required this.scope,
    required this.changed,
    required this.affectedProduction,
    required this.selected,
    required this.commands,
    required this.uncertainties,
    required this.totalTestCount,
    this.changeAttribution = const [],
    this.affectedSymbols = const [],
    this.precisionFallbacks = const [],
    this.base,
    this.mergeBase,
  });

  final String scope; // none | targeted | workspace-expanded
  final List<ChangedPath> changed;
  final List<String> affectedProduction;
  final List<TestSelection> selected;
  final List<TestCommand> commands;
  final List<String> uncertainties;
  final int totalTestCount;
  final List<ChangeAttribution> changeAttribution;
  final List<String> affectedSymbols;
  final List<String> precisionFallbacks;
  final String? base;
  final String? mergeBase;

  bool get expanded => scope == 'workspace-expanded';

  String get mode => expanded
      ? 'all'
      : scope == 'none'
          ? 'none'
          : 'targeted';

  Map<String, dynamic> toJson({required int budget}) => {
        ...envelope('affected-tests', base ?? 'explicit paths'),
        'scope': scope,
        'mode': mode,
        'runAll': expanded,
        // Targeted planning is deliberately advisory until the mutation
        // benchmark proves zero omitted failing suites. Expansion runs the
        // owning package/workspace suites and therefore skips nothing.
        'safeToSkipUnselected': expanded,
        'confidence': expanded
            ? 'expanded'
            : affectedSymbols.isNotEmpty
                ? 'resolved-symbol-advisory'
                : 'conservative-static',
        if (base != null) 'base': base,
        if (mergeBase != null) 'mergeBase': mergeBase,
        'changed': changed.map((c) => c.toJson()).toList(),
        'changeAttribution':
            changeAttribution.map((entry) => entry.toJson()).toList(),
        'affectedSymbols': affectedSymbols,
        'semanticAttribution': affectedSymbols.isNotEmpty,
        'precisionFallbacks': precisionFallbacks,
        // Machine plans are executable contracts: never budget-truncate test
        // paths or evidence. `--budget` applies to text rendering only.
        'affectedProduction': affectedProduction,
        'affectedProductionCount': affectedProduction.length,
        'selected': selected.map((s) => s.toJson()).toList(),
        'selectedCount': selected.length,
        'totalTestCount': totalTestCount,
        'reduction':
            totalTestCount == 0 ? 0 : 1 - (selected.length / totalTestCount),
        'commands': commands.map((c) => c.toJson()).toList(),
        'uncertainties': uncertainties,
        'expansions': [
          for (final message in uncertainties)
            {'code': _expansionCode(message), 'message': message},
        ],
        'recommendedNext': expanded
            ? 'run every command in this plan'
            : 'run the targeted commands, then the full suite until the mutation oracle unlocks safe skipping',
      };
}

class _Package {
  _Package(this.root, this.name, this.flutter);
  final String root;
  final String name;
  final bool flutter;
}

class _TestRecord {
  _TestRecord(this.path, this.packageRoot, this.dependencies, this.parseError);
  final String path;
  final String packageRoot;
  final Set<String> dependencies;
  final bool parseError;

  bool get entrypoint => path.endsWith('_test.dart');
  String get kind => path.contains('/integration_test/') ||
          path.startsWith('integration_test/')
      ? 'integration'
      : path.contains('/patrol_test/') || path.startsWith('patrol_test/')
          ? 'patrol'
          : 'unit';
}

class _TestIndex {
  _TestIndex(this.packages, this.records, this.uncertainties);
  final List<_Package> packages;
  final Map<String, _TestRecord> records;
  final List<String> uncertainties;

  Iterable<_TestRecord> get entrypoints =>
      records.values.where((r) => r.entrypoint);

  Set<String> closureOf(String start) {
    final seenTests = <String>{};
    final coveredLibs = <String>{};
    final queue = <String>[start];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!seenTests.add(current)) continue;
      final record = records[current];
      if (record == null) continue;
      for (final dep in record.dependencies) {
        if (records.containsKey(dep)) {
          queue.add(dep);
        } else if (_isProductionDart(dep)) {
          coveredLibs.add(dep);
        }
      }
    }
    return coveredLibs;
  }

  Set<String> entrypointsDependingOnTestPaths(Set<String> changedTests) {
    final reverse = <String, Set<String>>{};
    for (final record in records.values) {
      for (final dep in record.dependencies.where(records.containsKey)) {
        reverse.putIfAbsent(dep, () => {}).add(record.path);
      }
    }
    final affected = <String>{...changedTests};
    final queue = <String>[...changedTests];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final dependent in reverse[current] ?? const <String>{}) {
        if (affected.add(dependent)) queue.add(dependent);
      }
    }
    return records.values
        .where((r) => r.entrypoint && affected.contains(r.path))
        .map((r) => r.path)
        .toSet();
  }
}

bool _isProductionDart(String path) =>
    path.endsWith('.dart') &&
    (path.startsWith('lib/') ||
        RegExp(r'^[^/]+(?:/[^/]+)*/lib/').hasMatch(path));

bool _isTestPath(String path) => _testDirs.any(
      (root) => path.startsWith('$root/') || path.contains('/$root/'),
    );

bool _plannerRelevant(String path) =>
    !path.startsWith('docs/maps/') &&
    !path.startsWith('.dart_tool/') &&
    !path.startsWith('build/');

String _normalize(String path) {
  final out = <String>[];
  for (final segment in path.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(segment);
    }
  }
  return out.join('/');
}

String _join(String root, String child) =>
    root == '.' ? _normalize(child) : _normalize('$root/$child');

String? _pubspecName(String root) {
  final file = File(_join(root, 'pubspec.yaml'));
  if (!file.existsSync()) return null;
  return RegExp(r'^name:\s*(\S+)', multiLine: true)
      .firstMatch(file.readAsStringSync())
      ?.group(1);
}

bool _isFlutterPackage(String root) {
  final file = File(_join(root, 'pubspec.yaml'));
  if (!file.existsSync()) return false;
  final source = file.readAsStringSync();
  return RegExp(r'^\s*flutter:\s*$', multiLine: true).hasMatch(source) ||
      source.contains('sdk: flutter') ||
      (root == '.' && File('.metadata').existsSync());
}

List<_Package> _packages(Graph graph) {
  final roots = <String>{'.'};
  for (final node in graph.nodes.where((n) => n.isFile)) {
    final path = bare(node.id);
    final marker = path.indexOf('/lib/');
    if (marker > 0) roots.add(path.substring(0, marker));
  }
  final sorted = roots.toList()..sort();
  return [
    for (final root in sorted)
      if (_pubspecName(root) case final name?)
        _Package(root, name, _isFlutterPackage(root)),
  ];
}

Iterable<File> _dartFiles(String root) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  final files = dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  yield* files;
}

_TestIndex _scanTests(Graph graph) {
  final packages = _packages(graph);
  final byName = {for (final package in packages) package.name: package};
  final records = <String, _TestRecord>{};
  final uncertainties = <String>[];

  String? resolveUri(String sourcePath, String uri) {
    if (uri.startsWith('dart:') ||
        (uri.contains(':') && !uri.startsWith('package:'))) {
      return null;
    }
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final package = byName[rest.substring(0, slash)];
      if (package == null) return null; // external dependency
      return _join(package.root, 'lib/${rest.substring(slash + 1)}');
    }
    final slash = sourcePath.lastIndexOf('/');
    final parent = slash < 0 ? '.' : sourcePath.substring(0, slash);
    return _join(parent, uri);
  }

  for (final package in packages) {
    for (final testDir in _testDirs) {
      final root = _join(package.root, testDir);
      for (final file in _dartFiles(root)) {
        final path = _normalize(file.path);
        final source = file.readAsStringSync();
        final parsed = parseString(content: source, throwIfDiagnostics: false);
        final deps = <String>{};

        void add(String? uri) {
          if (uri == null) return;
          final resolved = resolveUri(path, uri);
          if (resolved == null) return;
          deps.add(resolved);
          if (!File(resolved).existsSync()) {
            uncertainties
                .add('$path has unresolved local dependency $resolved');
          }
        }

        for (final directive in parsed.unit.directives) {
          if (directive is ImportDirective) {
            add(directive.uri.stringValue);
            for (final config in directive.configurations) {
              add(config.uri.stringValue);
            }
          } else if (directive is ExportDirective) {
            add(directive.uri.stringValue);
            for (final config in directive.configurations) {
              add(config.uri.stringValue);
            }
          } else if (directive is PartDirective) {
            add(directive.uri.stringValue);
          } else if (directive is PartOfDirective) {
            final uri = directive.uri?.stringValue;
            if (uri == null) {
              uncertainties.add('$path uses an unresolved by-name part-of');
            } else {
              add(uri);
            }
          }
        }
        if (parsed.errors.isNotEmpty) {
          uncertainties.add('$path has analyzer parse errors');
        }
        records[path] = _TestRecord(
          path,
          package.root,
          deps,
          parsed.errors.isNotEmpty,
        );
      }
    }

    final config = File(_join(package.root, 'dart_test.yaml'));
    if (config.existsSync()) {
      final source = config.readAsStringSync();
      if (RegExp(r'^\s*(paths|filename|include):', multiLine: true)
          .hasMatch(source)) {
        uncertainties.add(
          '${_normalize(config.path)} changes test discovery beyond standard *_test.dart roots',
        );
      }
    }
  }
  return _TestIndex(packages, records, uncertainties.toSet().toList()..sort());
}

Set<String> _affectedProduction(Graph graph, Set<String> changed) {
  final affected = <String>{for (final path in changed) 'file:$path'};
  var frontier = <String>{...affected};
  while (frontier.isNotEmpty) {
    final next = <String>{...dependentsOf(graph, frontier)};
    for (final edge in graph.edges) {
      if (edge.rel == 'navigates-to' && frontier.contains(edge.dst)) {
        next.add(edge.src);
      }
    }
    next.removeWhere((id) => !id.startsWith('file:') || affected.contains(id));
    affected.addAll(next);
    frontier = next;
  }
  return affected.map(bare).toSet();
}

class _ExecutableSpan {
  const _ExecutableSpan({
    required this.key,
    required this.scopeStartLine,
    required this.scopeEndLine,
    required this.bodyStartLine,
    required this.bodyEndLine,
  });

  final String key;
  final int scopeStartLine;
  final int scopeEndLine;
  final int bodyStartLine;
  final int bodyEndLine;
}

String _declarationKey(String? owner, String name, String kind) =>
    '${owner ?? ''}::$kind::$name';

String? _syntaxOwner(AstNode node) {
  AstNode? parent = node.parent;
  while (parent != null) {
    if (parent is ClassDeclaration) {
      return parent.namePart.toSource().split('<').first.trim();
    }
    if (parent is MethodDeclaration) return parent.name.lexeme;
    if (parent is FunctionDeclaration) return parent.name.lexeme;
    parent = parent.parent;
  }
  return null;
}

class _ExecutableSpanVisitor extends RecursiveAstVisitor<void> {
  _ExecutableSpanVisitor(this.lines, this.spans);

  final LineInfo lines;
  final List<_ExecutableSpan> spans;

  int _line(int offset) => lines.getLocation(offset).lineNumber;

  void _add(
    AstNode node,
    FunctionBody body,
    String name,
    String kind,
  ) {
    spans.add(_ExecutableSpan(
      key: _declarationKey(_syntaxOwner(node), name, kind),
      scopeStartLine: _line(node.offset),
      scopeEndLine: _line(node.end - 1),
      bodyStartLine: _line(body.offset),
      bodyEndLine: _line(body.end - 1),
    ));
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _add(node, node.body, node.name.lexeme, 'method');
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _add(
      node,
      node.functionExpression.body,
      node.name.lexeme,
      'function',
    );
    super.visitFunctionDeclaration(node);
  }
}

List<_ExecutableSpan>? _oldExecutableSpans(String mergeBase, String path) {
  final old = runGit(['show', '$mergeBase:$path']);
  if (old == null || old.exitCode != 0) return null;
  final parsed = parseString(
    content: old.stdout as String,
    path: path,
    throwIfDiagnostics: false,
  );
  if (parsed.errors.isNotEmpty) return null;
  final spans = <_ExecutableSpan>[];
  parsed.unit.accept(_ExecutableSpanVisitor(parsed.lineInfo, spans));
  return spans;
}

bool _rangeInsideBody(
  _ExecutableSpan span,
  int start,
  int count,
) {
  // Git uses a zero count for pure insertions/deletions. Treat the reported
  // point as attributable only when it is strictly inside the declaration;
  // edits on the signature/opening or closing line remain structural.
  final end = count == 0 ? start : start + count - 1;
  return start > span.scopeStartLine &&
      end < span.scopeEndLine &&
      start >= span.bodyStartLine &&
      end <= span.bodyEndLine;
}

class _SemanticImpact {
  _SemanticImpact({
    required this.affectedProduction,
    required this.testPaths,
    required this.fileFallbacks,
    required this.attribution,
    required this.affectedSymbols,
    required this.precisionFallbacks,
  });

  final Set<String> affectedProduction;
  final Set<String> testPaths;
  final Set<String> fileFallbacks;
  final List<ChangeAttribution> attribution;
  final Set<String> affectedSymbols;
  final List<String> precisionFallbacks;
}

_SemanticImpact _semanticImpact(
  Graph graph,
  List<ChangedPath> changes,
  String? mergeBase,
) {
  final production =
      changes.where((change) => _isProductionDart(change.path)).toList();
  final fallbacks = <String>{};
  final attribution = <ChangeAttribution>[];
  final precisionFallbacks = <String>[];
  final starts = <String>{};
  final index = RefactorIndex.load();
  final indexReady = index != null &&
      index.complete &&
      index.sourceDigest == graph.stats['sourceDigest'];

  void fallback(ChangedPath change, String reason) {
    if (change.status != 'D') fallbacks.add(change.path);
    attribution.add(ChangeAttribution(
      change.path,
      'file-fallback',
      const [],
      reason,
    ));
    precisionFallbacks.add('${change.path}: $reason');
  }

  for (final change in production) {
    if (change.status != 'M') {
      fallback(change, 'only tracked modifications support symbol attribution');
      continue;
    }
    if (!indexReady) {
      fallback(
          change, 'resolved refactor index is missing, stale, or incomplete');
      continue;
    }
    if (mergeBase == null || !change.rangesKnown || change.ranges.isEmpty) {
      fallback(change, 'Git hunk ranges are unavailable');
      continue;
    }
    final currentFile = File(change.path);
    final currentSource = currentFile.readAsStringSync();
    final oldSpans = _oldExecutableSpans(mergeBase, change.path);
    if (oldSpans == null) {
      fallback(change, 'the merge-base source could not be parsed');
      continue;
    }
    final declarations = index.declarations
        .where((declaration) => declaration.file == change.path)
        .toList();
    final currentSpans = <RefactorDeclaration, _ExecutableSpan>{
      for (final declaration in declarations)
        declaration: _ExecutableSpan(
          key: _declarationKey(
            declaration.owner,
            declaration.name,
            declaration.declarationKind,
          ),
          scopeStartLine: declaration.scopeStartLine,
          scopeEndLine: declaration.scopeEndLine,
          bodyStartLine: declaration.bodyStartLine,
          bodyEndLine: declaration.bodyEndLine,
        ),
    };
    final attributed = <RefactorDeclaration>{};
    var unsafe = false;
    for (final range in change.ranges) {
      final oldMatches = oldSpans
          .where(
              (span) => _rangeInsideBody(span, range.oldStart, range.oldCount))
          .toList();
      final newMatches = currentSpans.entries
          .where((entry) => _rangeInsideBody(
                entry.value,
                range.newStart,
                range.newCount,
              ))
          .toList();
      if (oldMatches.length != 1 ||
          newMatches.length != 1 ||
          oldMatches.single.key != newMatches.single.value.key) {
        unsafe = true;
        break;
      }
      attributed.add(newMatches.single.key);
    }
    if (unsafe || attributed.isEmpty) {
      fallback(change, 'a hunk crosses a stable executable body boundary');
      continue;
    }
    if (currentFile.readAsStringSync() != currentSource) {
      fallback(change, 'the source changed while attribution was running');
      continue;
    }
    final externalOverride = attributed.any((declaration) =>
        declaration.overrides.any((parent) => !index.declarations
            .any((candidate) => candidate.symbol == parent)));
    final generatedBoundary = attributed.any((declaration) {
      if (declaration.scopeOffset < 0 ||
          declaration.bodyOffset < declaration.scopeOffset ||
          declaration.bodyOffset > currentSource.length) {
        return true;
      }
      final prefix = currentSource.substring(
        declaration.scopeOffset,
        declaration.bodyOffset,
      );
      return RegExp(r'@(riverpod|Riverpod)\b').hasMatch(prefix);
    });
    final unresolved = attributed.any(
      (declaration) => index.unresolvedNames.contains(declaration.name),
    );
    if (externalOverride || generatedBoundary || unresolved) {
      fallback(
        change,
        externalOverride
            ? 'the executable participates in an external override boundary'
            : generatedBoundary
                ? 'generated provider dispatch requires file-level coverage'
                : 'a dynamic or unresolved same-name reference exists',
      );
      continue;
    }
    final symbols = attributed.map((declaration) => declaration.symbol).toList()
      ..sort();
    starts.addAll(symbols);
    attribution.add(ChangeAttribution(
      change.path,
      'resolved-symbol',
      symbols,
      null,
    ));
  }

  if (!indexReady || starts.isEmpty) {
    return _SemanticImpact(
      affectedProduction: const {},
      testPaths: const {},
      fileFallbacks: fallbacks,
      attribution: attribution,
      affectedSymbols: const {},
      precisionFallbacks: precisionFallbacks,
    );
  }

  final overrideEdges = <String, Set<String>>{};
  for (final target in index.targets) {
    for (final parent in target.overrides) {
      overrideEdges.putIfAbsent(target.symbol, () => {}).add(parent);
      overrideEdges.putIfAbsent(parent, () => {}).add(target.symbol);
    }
  }
  final references = <String, List<RefactorSite>>{};
  for (final site in index.references) {
    references.putIfAbsent(site.symbol, () => []).add(site);
  }
  final affectedSymbols = <String>{};
  final affectedProduction = <String>{};
  final testPaths = <String>{};
  final queue = <String>[...starts];
  while (queue.isNotEmpty) {
    final symbol = queue.removeLast();
    if (!affectedSymbols.add(symbol)) continue;
    for (final related in overrideEdges[symbol] ?? const <String>{}) {
      if (!affectedSymbols.contains(related)) queue.add(related);
    }
    for (final site in references[symbol] ?? const <RefactorSite>[]) {
      if (_isTestPath(site.file)) {
        testPaths.add(site.file);
      } else if (_isProductionDart(site.file)) {
        affectedProduction.add(site.file);
        final owner = site.containerSymbol;
        if (owner == null) {
          fallbacks.add(site.file);
          precisionFallbacks.add(
            '${site.file}: reference occurs outside an executable body',
          );
        } else if (!affectedSymbols.contains(owner)) {
          queue.add(owner);
        }
      }
    }
  }
  return _SemanticImpact(
    affectedProduction: affectedProduction,
    testPaths: testPaths,
    fileFallbacks: fallbacks,
    attribution: attribution,
    affectedSymbols: affectedSymbols,
    precisionFallbacks: precisionFallbacks.toSet().toList()..sort(),
  );
}

List<String> _changeUncertainties(List<ChangedPath> changes, Graph graph) {
  final reasons = <String>[];
  const globalFiles = {
    'pubspec.yaml',
    'pubspec.lock',
    'pubspec_overrides.yaml',
    'build.yaml',
    'dart_test.yaml',
    'analysis_options.yaml',
    '.metadata',
    '.dart_tool/package_config.json',
  };
  for (final change in changes) {
    final path = change.path;
    if (!const {'A', 'M', 'D'}.contains(change.status)) {
      reasons.add(
        '$path has unsupported or incomplete change status ${change.status}',
      );
    }
    if (change.status == 'D' && path.endsWith('.dart')) {
      reasons
          .add('$path was deleted; its old dependency edges are unavailable');
    }
    if (globalFiles.contains(path) || path.endsWith('/dart_test.yaml')) {
      reasons.add('$path changes package, generator, or test configuration');
    }
    if (_generatedSuffixes.any(path.endsWith)) {
      reasons.add('$path is generated output with no proven source mapping');
    }
    if (RegExp(r'^(android|ios|macos|windows|linux|web)/').hasMatch(path)) {
      reasons.add('$path changes platform-specific application behavior');
    }
    final knownPath = _isProductionDart(path) ||
        _isTestPath(path) ||
        globalFiles.contains(path) ||
        path.endsWith('/dart_test.yaml') ||
        _generatedSuffixes.any(path.endsWith) ||
        RegExp(r'^(android|ios|macos|windows|linux|web)/').hasMatch(path) ||
        RegExp(r'(^|/)(golden|goldens|assets?)(/|$)').hasMatch(path) ||
        RegExp(r'\.(png|jpg|jpeg|gif|webp|ttf|otf)$').hasMatch(path);
    if (!knownPath) {
      reasons
          .add('$path has no proven relationship to the test dependency graph');
    }
    if (RegExp(r'(^|/)(golden|goldens|assets?)(/|$)').hasMatch(path) ||
        RegExp(r'\.(png|jpg|jpeg|gif|webp|ttf|otf)$').hasMatch(path)) {
      reasons.add('$path may affect asset, font, or golden behavior');
    }
    if (_isProductionDart(path) && change.status != 'D') {
      if (graph.byId['file:$path'] == null) {
        reasons.add('$path is not represented in the current production graph');
      }
      final file = File(path);
      if (file.existsSync()) {
        final source = file.readAsStringSync();
        if (RegExp(r'@(freezed|JsonSerializable|TypedGoRoute)\b')
                .hasMatch(source) ||
            RegExp(r'''\bpart\s+['"][^'"]+\.(freezed|gr)\.dart['"]''')
                .hasMatch(source)) {
          reasons
              .add('$path is a generated-code input without output provenance');
        }
        if (source.contains('ProviderScope(') ||
            source.contains('ProviderContainer(') ||
            source.contains('runApp(')) {
          reasons.add('$path changes global application/provider lifecycle');
        }
        if (RegExp(r'\b(StatefulShellRoute|GoRouter|redirect:)')
            .hasMatch(source)) {
          reasons.add('$path changes global routing or redirect policy');
        }
        if (RegExp(r'''\b(import|export)\s+['"][^'"]+['"]\s+if\s*\(''')
            .hasMatch(source)) {
          reasons.add('$path contains platform-conditional dependency edges');
        }
      }
    }
  }
  if ((graph.stats['parseErrorFiles'] ?? 0) > 0) {
    reasons.add('the production graph was built with analyzer parse errors');
  }
  if (!freshnessChecked || !lastLoadFresh) {
    reasons.add('graph freshness was not proven for this plan');
  }
  if ((graph.stats['format'] ?? 0) != graphFormatVersion) {
    reasons
        .add('graph format is not exactly the format this planner understands');
  }
  return reasons.toSet().toList()..sort();
}

AffectedTestPlan buildAffectedTestPlan(
  Graph graph,
  List<ChangedPath> changed, {
  String? base,
  String? mergeBase,
}) {
  final index = _scanTests(graph);
  final uncertainties = <String>[
    ..._changeUncertainties(changed, graph),
    ...index.uncertainties,
  ];
  final semantic = _semanticImpact(graph, changed, mergeBase);
  final fileAffected = _affectedProduction(graph, semantic.fileFallbacks);
  final affected = <String>{
    ...fileAffected,
    ...semantic.affectedProduction,
  };
  final changedTests = changed
      .where((c) => _isTestPath(c.path) && c.path.endsWith('.dart'))
      .map((c) => c.path)
      .toSet();
  final directTestEntries = index.entrypointsDependingOnTestPaths(changedTests);
  final semanticTestEntries =
      index.entrypointsDependingOnTestPaths(semantic.testPaths);
  for (final changedTest in changedTests) {
    if (changedTest.endsWith('_test.dart') && !File(changedTest).existsSync()) {
      continue; // deleted entrypoints must not be executed
    }
    if (index.entrypointsDependingOnTestPaths({changedTest}).isEmpty) {
      uncertainties.add(
        '$changedTest maps to zero runnable test entrypoints',
      );
    }
  }

  final selection = <String, TestSelection>{};
  for (final test in index.entrypoints) {
    final covered = index.closureOf(test.path);
    final evidence = covered.intersection(fileAffected).toList()..sort();
    if (evidence.isNotEmpty ||
        directTestEntries.contains(test.path) ||
        semanticTestEntries.contains(test.path)) {
      selection[test.path] = TestSelection(
        test.path,
        test.packageRoot,
        test.kind,
        [
          if (directTestEntries.contains(test.path))
            'changed test or test helper',
          if (semanticTestEntries.contains(test.path))
            'references an affected resolved symbol',
          for (final file in evidence.take(5)) 'imports affected $file',
        ],
      );
    }
  }

  final productionChanges = changed.any((c) => _isProductionDart(c.path));
  if (productionChanges && selection.isEmpty && index.entrypoints.isNotEmpty) {
    uncertainties.add('production changes selected zero tests');
  }
  if (selection.values.any((test) => test.kind == 'patrol')) {
    uncertainties
        .add('Patrol execution requires project-specific device configuration');
  }

  final expanded = uncertainties.isNotEmpty;
  if (expanded) {
    selection.clear();
    for (final test in index.entrypoints) {
      selection[test.path] = TestSelection(
        test.path,
        test.packageRoot,
        test.kind,
        ['workspace expansion: ${uncertainties.first}'],
      );
    }
  }
  final selected = selection.values.toList()
    ..sort((a, b) => a.file.compareTo(b.file));
  final commands = _commands(index.packages, selected, expanded: expanded);
  return AffectedTestPlan(
    scope: expanded
        ? 'workspace-expanded'
        : selected.isEmpty
            ? 'none'
            : 'targeted',
    changed: changed,
    affectedProduction: affected.toList()..sort(),
    selected: selected,
    commands: commands,
    uncertainties: uncertainties.toSet().toList()..sort(),
    totalTestCount: index.entrypoints.length,
    changeAttribution: semantic.attribution
      ..sort((a, b) => a.path.compareTo(b.path)),
    affectedSymbols: semantic.affectedSymbols.toList()..sort(),
    precisionFallbacks: semantic.precisionFallbacks,
    base: base,
    mergeBase: mergeBase,
  );
}

String _expansionCode(String message) {
  if (message.contains('deleted')) return 'deleted_input';
  if (message.contains('configuration')) return 'configuration_change';
  if (message.contains('generated')) return 'generated_boundary';
  if (message.contains('platform')) return 'platform_change';
  if (message.contains('asset') || message.contains('golden')) {
    return 'asset_or_golden';
  }
  if (message.contains('parse error')) return 'partial_parse';
  if (message.contains('freshness')) return 'stale_graph';
  if (message.contains('format')) return 'graph_format';
  if (message.contains('routing') || message.contains('redirect')) {
    return 'global_route';
  }
  if (message.contains('lifecycle')) return 'global_lifecycle';
  if (message.contains('conditional')) return 'conditional_uri';
  if (message.contains('zero tests')) return 'empty_selection';
  if (message.contains('Patrol')) return 'unknown_runner';
  if (message.contains('unresolved')) return 'unresolved_import';
  if (message.contains('status')) return 'incomplete_change_set';
  return 'unknown_change';
}

List<TestCommand> _commands(
  List<_Package> packages,
  List<TestSelection> selected, {
  required bool expanded,
}) {
  final byRoot = {for (final package in packages) package.root: package};
  final grouped = <(String, String), List<TestSelection>>{};
  for (final test in selected) {
    grouped.putIfAbsent((test.packageRoot, test.kind), () => []).add(test);
  }
  final commands = <TestCommand>[];
  if (expanded) {
    // A no-path unit command intentionally delegates discovery to package:test
    // / flutter_test and dart_test.yaml. That is strictly safer than listing
    // only the standard entrypoints our static scanner discovered.
    for (final package in packages) {
      final runner = package.flutter ? 'flutter' : 'dart';
      commands.add(TestCommand(
        package.root,
        runner,
        'unit',
        [runner, 'test'],
      ));
      final kinds = selected
          .where((test) => test.packageRoot == package.root)
          .map((test) => test.kind)
          .toSet();
      if (kinds.contains('integration')) {
        commands.add(TestCommand(
          package.root,
          'flutter',
          'integration',
          const ['flutter', 'test', 'integration_test', '-d', '<device>'],
          requiresDevice: true,
        ));
      }
      if (kinds.contains('patrol')) {
        commands.add(TestCommand(
          package.root,
          'patrol',
          'patrol',
          const ['patrol', 'test'],
          requiresDevice: true,
        ));
      }
    }
    commands.sort((a, b) {
      final root = a.workingDirectory.compareTo(b.workingDirectory);
      return root != 0 ? root : a.kind.compareTo(b.kind);
    });
    return commands;
  }
  for (final entry in grouped.entries) {
    final root = entry.key.$1;
    final kind = entry.key.$2;
    final package = byRoot[root]!;
    final tests = entry.value..sort((a, b) => a.file.compareTo(b.file));
    String relative(String path) => root == '.'
        ? path
        : path.startsWith('$root/')
            ? path.substring(root.length + 1)
            : path;
    if (kind == 'patrol') {
      commands.add(TestCommand(root, 'patrol', kind, const ['patrol', 'test'],
          requiresDevice: true));
      continue;
    }
    final runner = kind == 'integration'
        ? 'flutter'
        : package.flutter
            ? 'flutter'
            : 'dart';
    final argv = <String>[runner, 'test'];
    argv.addAll(tests.map((t) => relative(t.file)));
    if (kind == 'integration') argv.addAll(const ['-d', '<device>']);
    commands.add(TestCommand(
      root,
      runner,
      kind,
      argv,
      requiresDevice: kind == 'integration',
    ));
  }
  commands.sort((a, b) {
    final root = a.workingDirectory.compareTo(b.workingDirectory);
    return root != 0 ? root : a.kind.compareTo(b.kind);
  });
  return commands;
}

({bool known, List<ChangedLineRange> ranges}) _gitHunks(
  String mergeBase,
  String path,
) {
  final diff = runGit([
    '--no-pager',
    '--literal-pathspecs',
    'diff',
    '--patch',
    '--unified=0',
    '--no-ext-diff',
    '--no-textconv',
    '--no-color',
    '--no-relative',
    '--ignore-submodules=none',
    '--diff-algorithm=myers',
    '--no-indent-heuristic',
    '--no-renames',
    mergeBase,
    '--',
    path,
  ]);
  if (diff == null || diff.exitCode != 0) {
    return (known: false, ranges: const []);
  }
  final source = diff.stdout as String;
  final header = RegExp(
    r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
    multiLine: true,
  );
  final ranges = <ChangedLineRange>[];
  for (final match in header.allMatches(source)) {
    ranges.add(ChangedLineRange(
      oldStart: int.parse(match.group(1)!),
      oldCount: int.parse(match.group(2) ?? '1'),
      newStart: int.parse(match.group(3)!),
      newCount: int.parse(match.group(4) ?? '1'),
    ));
  }
  return (known: source.isNotEmpty && ranges.isNotEmpty, ranges: ranges);
}

({List<ChangedPath> changes, String base, String mergeBase})? _gitChanges(
    String? requestedBase) {
  String? base = requestedBase;
  if (base == null) {
    for (final candidate in ['origin/main', 'main', 'master']) {
      final result = runGit(['rev-parse', '--verify', '-q', candidate]);
      if (result == null) return null;
      if (result.exitCode == 0) {
        base = candidate;
        break;
      }
    }
  }
  if (base == null) return null;
  final verify = runGit(
      ['rev-parse', '--verify', '-q', '--end-of-options', '$base^{commit}']);
  if (verify == null || verify.exitCode != 0) return null;
  final baseOid = (verify.stdout as String).trim();
  final merge = runGit(['merge-base', baseOid, 'HEAD']);
  if (merge == null || merge.exitCode != 0) return null;
  final mergeBase = (merge.stdout as String).trim();
  final diff = runGit([
    '--no-pager',
    'diff',
    '--name-status',
    '-z',
    '--find-renames=50%',
    '--no-ext-diff',
    '--no-textconv',
    '--no-color',
    '--no-relative',
    '--ignore-submodules=none',
    '--ita-invisible-in-index',
    mergeBase,
    '--',
  ]);
  if (diff == null || diff.exitCode != 0) return null;
  final changes = <ChangedPath>[];
  final fields = (diff.stdout as String).split('\x00');
  var field = 0;
  while (field < fields.length && fields[field].isNotEmpty) {
    final status = fields[field++];
    if ((status.startsWith('R') || status.startsWith('C')) &&
        field + 1 < fields.length) {
      final oldPath = fields[field++];
      final newPath = fields[field++];
      if (_plannerRelevant(oldPath)) changes.add(ChangedPath('D', oldPath));
      if (_plannerRelevant(newPath)) changes.add(ChangedPath('A', newPath));
    } else if (field < fields.length) {
      final path = fields[field++];
      if (_plannerRelevant(path)) {
        changes.add(ChangedPath(status.substring(0, 1), path));
      }
    }
  }
  final untracked = runGit([
    'ls-files',
    '--others',
    '--exclude-standard',
    '--full-name',
    '-z',
    '--',
  ]);
  if (untracked != null && untracked.exitCode == 0) {
    final known = changes.map((c) => c.path).toSet();
    for (final path in (untracked.stdout as String).split('\x00')) {
      if (path.isNotEmpty && _plannerRelevant(path) && known.add(path)) {
        changes.add(ChangedPath('A', path));
      }
    }
  } else {
    changes.add(const ChangedPath('?', '<untracked files unavailable>'));
  }
  final rangedChanges = <ChangedPath>[];
  for (final change in changes) {
    if (change.status == 'M' && _isProductionDart(change.path)) {
      final hunks = _gitHunks(mergeBase, change.path);
      rangedChanges.add(ChangedPath(
        change.status,
        change.path,
        ranges: hunks.ranges,
        rangesKnown: hunks.known,
      ));
    } else {
      rangedChanges.add(change);
    }
  }
  rangedChanges.sort((a, b) => a.path.compareTo(b.path));
  return (changes: rangedChanges, base: base, mergeBase: mergeBase);
}

String? _stringFlag(List<String> args, String flag) {
  final index = args.indexOf(flag);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

int run(List<String> args) {
  final asJson = args.contains('--json');
  final budget = intFlag(args, '--budget') ?? 100;
  final positional = positionalArgs(args).skip(1).toList();
  final graph = loadFresh();
  if (graph == null) return 66;

  List<ChangedPath> changes;
  String? base;
  String? mergeBase;
  if (positional.isNotEmpty) {
    changes = [
      for (final path in positional)
        ChangedPath(File(path).existsSync() ? 'M' : 'D', _normalize(path)),
    ];
  } else {
    final discovered = _gitChanges(_stringFlag(args, '--base'));
    if (discovered == null) {
      changes = const [ChangedPath('?', '<git changes unavailable>')];
    } else {
      changes = discovered.changes;
      base = discovered.base;
      mergeBase = discovered.mergeBase;
    }
  }

  if (changes.isEmpty) {
    if (asJson) {
      stdout.writeln(jsonEncode({
        ...envelope('affected-tests', base ?? 'explicit paths'),
        'scope': 'none',
        'mode': 'none',
        'runAll': false,
        'safeToSkipUnselected': true,
        'confidence': 'conservative-static',
        'changed': const [],
        'selected': const [],
        'selectedCount': 0,
        'totalTestCount': 0,
        'commands': const [],
        'uncertainties': const [],
      }));
    } else {
      stdout.writeln('no changes; no affected test command needed');
    }
    return 0;
  }

  final plan = buildAffectedTestPlan(
    graph,
    changes,
    base: base,
    mergeBase: mergeBase,
  );
  if (asJson) {
    stdout.writeln(jsonEncode(plan.toJson(budget: budget)));
    return 0;
  }

  stdout.writeln('affected tests: ${plan.scope} — '
      '${plan.selected.length} test file(s), ${plan.commands.length} command(s)');
  stdout.writeln('changed: ${plan.changed.length}; affected production: '
      '${plan.affectedProduction.length}');
  if (plan.affectedSymbols.isNotEmpty) {
    stdout.writeln(
      'resolved symbol impact: ${plan.affectedSymbols.length} executable(s)',
    );
  }
  if (plan.precisionFallbacks.isNotEmpty && !plan.expanded) {
    stdout.writeln('precision fallbacks:');
    for (final fallback in plan.precisionFallbacks.take(budget)) {
      stdout.writeln('  - $fallback');
    }
  }
  if (!plan.expanded && plan.selected.isNotEmpty) {
    stdout.writeln('advisory: run these first, then run the full suite; safe '
        'skipping remains locked until the mutation oracle is complete');
  }
  if (plan.uncertainties.isNotEmpty) {
    stdout.writeln('expanded because:');
    for (final reason in plan.uncertainties) {
      stdout.writeln('  - $reason');
    }
  }
  if (plan.selected.isNotEmpty) {
    stdout.writeln('selected:');
    for (final test in plan.selected.take(budget)) {
      stdout.writeln('  ${test.file} — ${test.reasons.join('; ')}');
    }
    if (plan.selected.length > budget) {
      stdout.writeln('  … ${plan.selected.length - budget} more');
    }
  }
  if (plan.commands.isNotEmpty) {
    stdout.writeln('commands:');
    for (final command in plan.commands) {
      stdout.writeln('  (cd ${command.workingDirectory} && '
          '${command.argv.join(' ')})');
    }
  }
  return 0;
}
