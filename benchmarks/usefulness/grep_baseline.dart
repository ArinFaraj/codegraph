import 'dart:io';

/// Scripted grep/rg pipelines that approximate what an agent does without
/// codegraph. Recipes are documented in grep_baselines.yaml.
class GrepBaseline {
  GrepBaseline(this.root);

  final Directory root;

  static bool get available {
    final which = Process.runSync('which', ['rg']);
    return which.exitCode == 0 && which.stdout.toString().trim().isNotEmpty;
  }

  List<String> _dartFilesUnder(String dirName) {
    final d = Directory('${root.path}/$dirName');
    if (!d.existsSync()) return const [];
    return d
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => _rel(f.path))
        .toList()
      ..sort();
  }

  String _rel(String path) {
    final p = path.startsWith('${root.path}/')
        ? path.substring(root.path.length + 1)
        : path;
    return p.startsWith('./') ? p.substring(2) : p;
  }

  ProcessResult _rg(List<String> args) => Process.runSync(
        'rg',
        args,
        workingDirectory: root.path,
      );

  /// `rg -l` then filter — counts as one tool call per scenario in scoring.
  Set<String> filesMatching(String pattern,
      {List<String> roots = const ['lib', 'packages', 'test']}) {
    final out = <String>{};
    for (final r in roots) {
      final dir = Directory('${root.path}/$r');
      if (!dir.existsSync()) continue;
      final result = _rg(['-l', pattern, r]);
      if (result.exitCode > 1) continue;
      for (final line in result.stdout.toString().split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out;
  }

  /// Declaration files for a top-level/class symbol (noisy).
  Set<String> locateSymbol(String name) =>
      filesMatching('class $name', roots: ['lib', 'packages']);

  /// Textual "method exists" search — matches declarations, calls, comments.
  Set<String> locateMemberName(String name) =>
      filesMatching(name, roots: ['lib', 'packages']);

  /// Provider consumers: files mentioning [provider] with watch/read/listen.
  /// Includes false positives (comments, strings, tear-offs, declaration file).
  Set<String> providerReaders(String provider) {
    final hits = filesMatching(provider, roots: ['lib', 'packages', 'test']);
    final readers = <String>{};
    final decls = <String>{};
    for (final rel in hits) {
      final content = File('${root.path}/$rel').readAsStringSync();
      final isDecl = RegExp(
        'final\\s+$provider\\s*=|name:\\s*[\'"]$provider[\'"]',
      ).hasMatch(content);
      if (isDecl) {
        decls.add(rel);
        continue;
      }
      if (RegExp('(watch|read|listen)\\s*\\(\\s*$provider').hasMatch(content) ||
          RegExp('\\b$provider\\b').hasMatch(content)) {
        readers.add(rel);
      }
    }
    readers.removeAll(decls);
    return readers;
  }

  /// Bare name match — includes declaration, tear-offs, string literals.
  Set<String> callSitesByName(String symbol) {
    final out = <String>{};
    for (final r in ['lib', 'packages', 'test']) {
      final result = _rg(['-n', '\\b$symbol\\b', r]);
      if (result.exitCode > 1) continue;
      for (final line in result.stdout.toString().split('\n')) {
        if (line.trim().isEmpty) continue;
        final colon = line.indexOf(':');
        if (colon < 0) continue;
        final file = line.substring(0, colon);
        final rest = line.substring(colon + 1);
        final lineColon = rest.indexOf(':');
        if (lineColon < 0) continue;
        final filePath = file.trim();
        final lineNo = rest.substring(0, lineColon).trim();
        out.add('$filePath:$lineNo');
      }
    }
    return out;
  }

  /// Direct `extends`/`implements` only — misses transitive subtypes.
  Set<String> directSubtypesOf(String type) {
    final out = <String>{};
    for (final r in ['lib', 'packages']) {
      final result = _rg([
        '-l',
        'extends $type|implements $type|extends \\w+.*$type',
        r,
      ]);
      if (result.exitCode > 1) continue;
      for (final line in result.stdout.toString().split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out;
  }

  /// Importers of a file via package import path substring.
  Set<String> importersOfFilePath(String pathSuffix) {
    final needle = pathSuffix.replaceAll('/', '/');
    final out = <String>{};
    for (final r in ['lib', 'packages']) {
      final result = _rg(['-l', needle, r]);
      if (result.exitCode > 1) continue;
      for (final line in result.stdout.toString().split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty && !t.endsWith(pathSuffix)) out.add(t);
      }
    }
    return out;
  }

  /// One-hop import followers (reverse: who imports files that import seed).
  Set<String> impactOneHop(String fileSuffix) {
    final seedFiles = filesMatching(fileSuffix, roots: ['lib', 'packages'])
        .where((f) => f.endsWith(fileSuffix) || f.contains(fileSuffix))
        .toSet();
    if (seedFiles.isEmpty) return {};
    final importers = <String>{};
    for (final rel in _dartFilesUnder('lib')) {
      final content = File('${root.path}/$rel').readAsStringSync();
      for (final seed in seedFiles) {
        final importNeedle = seed.replaceAll('/', '/');
        if (content.contains(importNeedle)) importers.add(rel);
      }
    }
    for (final rel in _dartFilesUnder('packages')) {
      final content = File('${root.path}/$rel').readAsStringSync();
      for (final seed in seedFiles) {
        if (content.contains(seed.split('/').last.replaceAll('.dart', ''))) {
          importers.add(rel);
        }
      }
    }
    importers.removeAll(seedFiles);
    return importers;
  }

  /// Providers with token mention in tests but no import closure — very noisy.
  Set<String> untestedProvidersHeuristic(List<String> allProviderNames) {
    final untested = <String>{};
    for (final name in allProviderNames) {
      final inLib = filesMatching(name, roots: ['lib', 'packages']);
      final inTest = filesMatching(name, roots: ['test']);
      if (inLib.isNotEmpty && inTest.isEmpty) untested.add(name);
    }
    return untested;
  }
}
