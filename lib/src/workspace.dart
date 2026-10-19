import 'dart:convert';
import 'dart:io';

import 'package:analyzer/file_system/physical_file_system.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/context_locator.dart';

/// The repository codegraph answers for: the outermost directory above the
/// working directory that holds a `pubspec.yaml`, stopping at a git root.
class Workspace {
  Workspace._(this.root);

  final String root;

  static Workspace? find([String? from]) {
    var dir = Directory(from ?? Directory.current.path).absolute;
    try {
      dir = Directory(dir.resolveSymbolicLinksSync());
    } catch (_) {}
    String? candidate;
    while (true) {
      final path = _normalize(dir.path);
      if (File('$path/pubspec.yaml').existsSync()) candidate = path;
      if (Directory('$path/.git').existsSync() ||
          File('$path/.git').existsSync()) {
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return candidate == null ? null : Workspace._(candidate);
  }

  String get stateDir => '$root/.dart_tool/codegraph';

  String get packageConfig => '$root/.dart_tool/package_config.json';

  /// Why resolved analysis cannot run here, or null when it can.
  String? get unresolvableReason {
    final config = File(packageConfig);
    if (!config.existsSync()) {
      return 'no .dart_tool/package_config.json - run `flutter pub get` '
          '(or `dart pub get`) first';
    }
    final lock = File('$root/pubspec.lock');
    if (lock.existsSync() &&
        lock.lastModifiedSync().isAfter(config.lastModifiedSync())) {
      return 'pubspec.lock is newer than .dart_tool/package_config.json - '
          'run `flutter pub get` first';
    }
    return null;
  }

  /// [path] relative to the workspace root, or null when it lies outside.
  String? relativeOrNull(String path) {
    final p = _normalize(absolute(path));
    if (p == root) return '.';
    return p.startsWith('$root/') ? p.substring(root.length + 1) : null;
  }

  bool contains(String path) => relativeOrNull(path) != null;

  /// [path] relative to the workspace root. Only for paths known to be
  /// inside it; use [relativeOrNull] for anything that might not be.
  String relative(String path) =>
      relativeOrNull(path) ??
      (throw ArgumentError.value(path, 'path', 'outside ${root}'));

  String absolute(String path) =>
      path.startsWith('/') ? _normalize(path) : _normalize('$root/$path');

  /// Every Dart file `dart analyze` would analyze here, grouped by context
  /// root, honoring each root's `analysis_options.yaml` excludes.
  List<AnalyzedRoot> analyzedRoots() {
    final roots = locateContextRoots(
      includedPaths: [root],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );
    return [
      for (final r in roots)
        AnalyzedRoot(
          _normalize(r.root.path),
          [
            for (final f in r.analyzedFiles())
              if (f.endsWith('.dart')) _normalize(f),
          ]..sort(),
        ),
    ]..sort((a, b) => a.path.compareTo(b.path));
  }

  List<String> analyzedFiles() =>
      [for (final r in analyzedRoots()) ...r.files]..sort();

  /// Package name to root directory, for every package inside the
  /// workspace (the app and its path packages), from the package config.
  Map<String, String> packageRoots() {
    final out = <String, String>{};
    final config = File(packageConfig);
    if (config.existsSync()) {
      try {
        final j = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
        for (final p in j['packages'] as List) {
          final m = p as Map<String, dynamic>;
          final rootUri = m['rootUri'] as String;
          final uri = Uri.parse(rootUri);
          final abs = absolute(
            uri.hasScheme ? uri.toFilePath() : '$root/.dart_tool/$rootUri',
          );
          if (abs == root || abs.startsWith('$root/')) {
            out[m['name'] as String] = abs;
          }
        }
        return out;
      } catch (_) {}
    }
    for (final f in Directory(
      root,
    ).listSync(recursive: true, followLinks: false).whereType<File>()) {
      if (!f.path.endsWith('/pubspec.yaml')) continue;
      final rel = relative(f.path);
      if (rel.split('/').any((s) => s.startsWith('.') || s == 'build'))
        continue;
      final m = RegExp(
        r'^name:\s*(\S+)',
        multiLine: true,
      ).firstMatch(f.readAsStringSync());
      if (m != null) out[m.group(1)!] = absolute(f.parent.path);
    }
    return out;
  }

  /// Path packages under the workspace whose pubspec does not opt out of
  /// publishing. Renaming their public API can break consumers we cannot see.
  List<String> publishablePackageRoots() {
    final out = <String>[];
    for (final path in packageRoots().values) {
      if (path == root) continue;
      final pubspec = File('$path/pubspec.yaml');
      if (!pubspec.existsSync()) continue;
      if (RegExp(
        r'^publish_to:\s*["\x27]?none',
        multiLine: true,
      ).hasMatch(pubspec.readAsStringSync())) {
        continue;
      }
      out.add(path);
    }
    return out..sort();
  }

  /// Files whose change means the analysis contexts themselves must be rebuilt.
  List<String> configFiles() {
    final out = <String>[packageConfig];
    for (final r in analyzedRoots()) {
      out.add('${r.path}/pubspec.yaml');
      out.add('${r.path}/analysis_options.yaml');
    }
    out.add('$root/pubspec.lock');
    return out;
  }
}

class AnalyzedRoot {
  AnalyzedRoot(this.path, this.files);
  final String path;
  final List<String> files;
}

String _normalize(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final segments = <String>[];
  for (final s in p.split('/')) {
    if (s == '.' || (s.isEmpty && segments.isNotEmpty)) continue;
    if (s == '..' && segments.length > 1) {
      segments.removeLast();
      continue;
    }
    segments.add(s);
  }
  return segments.join('/');
}

bool isGeneratedFile(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.endsWith('.gr.dart') ||
    path.endsWith('.config.dart') ||
    path.endsWith('.mocks.dart') ||
    path.endsWith('.gen.dart');

bool isTestPath(String rel) =>
    rel.startsWith('test/') ||
    rel.startsWith('integration_test/') ||
    rel.contains('/test/') ||
    rel.contains('/integration_test/') ||
    rel.endsWith('_test.dart');
