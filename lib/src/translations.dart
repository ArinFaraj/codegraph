// Translation keys of a slang project: from a dotted key (or a Dart access
// such as `t.update.restart`) to its getter in the generated base locale, every
// Dart use of that getter, and the line defining it in each locale's YAML.
// The link is exact: slang's generated getters carry their dotted key, as in
// `TranslationOverrides.string(_root.$meta, 'update.restart', {})`.
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:yaml/yaml.dart';

import 'engine.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

/// Where a slang project keeps its strings, from `slang.yaml`.
class SlangConfig {
  SlangConfig(this.inputDir, this.pattern, this.baseFile, this.baseLocale);

  /// Workspace-relative.
  final String inputDir;
  final String pattern;
  final String baseFile;
  final String baseLocale;

  static SlangConfig? read(Workspace ws) {
    final file = File('${ws.root}/slang.yaml');
    if (!file.existsSync()) return null;
    final Object? parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on Exception {
      return null;
    }
    if (parsed is! Map) return null;
    final y = parsed;
    String option(String key, String fallback) => switch (y[key]) {
      final String s => s,
      _ => fallback,
    };
    final input = option('input_directory', 'lib/i18n');
    final output = option('output_directory', input);
    final base = option('base_locale', 'en');
    final name = option('output_file_name', 'strings.g.dart');
    final stem = name.replaceFirst(RegExp(r'(\.g)?\.dart$'), '');
    final split = '$output/${stem}_$base.g.dart';
    return SlangConfig(
      input,
      option('input_file_pattern', '.i18n.json'),
      File('${ws.root}/$split').existsSync() ? split : '$output/$name',
      base,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SlangConfig &&
      other.inputDir == inputDir &&
      other.pattern == pattern &&
      other.baseFile == baseFile &&
      other.baseLocale == baseLocale;

  @override
  int get hashCode => Object.hash(inputDir, pattern, baseFile, baseLocale);

  /// Locale to its workspace-relative YAML file, base locale first.
  Map<String, String> localeFiles(Workspace ws) {
    final dir = Directory('${ws.root}/$inputDir');
    if (!dir.existsSync()) return const {};
    final out = <String, String>{};
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith(pattern) || !name.endsWith('.yaml')) continue;
      final stem = name.substring(0, name.length - pattern.length);
      out[stem.contains('_')
              ? stem.substring(stem.lastIndexOf('_') + 1)
              : stem] =
          '$inputDir/$name';
    }
    final locales = out.keys.toList()
      ..sort((a, b) {
        if (a == baseLocale) return -1;
        if (b == baseLocale) return 1;
        return a.compareTo(b);
      });
    return {for (final l in locales) l: out[l]!};
  }
}

/// Every key of the base locale to the getter or method that serves it.
class TranslationIndex {
  TranslationIndex(this.config, this.keys);

  final SlangConfig config;
  final Map<String, Element> keys;

  static Future<TranslationIndex?> build(
    Engine engine,
    SlangConfig config,
  ) async {
    if (!engine.analysis.isAnalyzed(config.baseFile)) return null;
    final unit = await engine.analysis.unit(config.baseFile);
    if (unit == null) return null;
    final keys = <String, Element>{};
    unit.unit.accept(_KeyFinder(keys));
    return keys.isEmpty ? null : TranslationIndex(config, keys);
  }

  /// The key [query] names: the query itself, or what is left after dropping
  /// leading segments, so `context.t.update.restart` finds `update.restart`.
  String? keyFor(String query) {
    final parts = query.split('.');
    for (var i = 0; i < parts.length; i++) {
      final key = parts.sublist(i).join('.');
      if (keys.containsKey(key)) return key;
    }
    return null;
  }
}

class _KeyFinder extends RecursiveAstVisitor<void> {
  _KeyFinder(this.keys);

  final Map<String, Element> keys;
  ExecutableElement? _member;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _member = node.declaredFragment?.element;
    super.visitMethodDeclaration(node);
    _member = null;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final args = node.argumentList.arguments;
    if (_member != null &&
        target is SimpleIdentifier &&
        target.name == 'TranslationOverrides' &&
        args.length >= 2 &&
        args[1] is SimpleStringLiteral) {
      keys.putIfAbsent((args[1] as SimpleStringLiteral).value, () => _member!);
    }
    super.visitMethodInvocation(node);
  }
}

/// Where one locale defines a key, or null when it does not.
class LocaleLine {
  LocaleLine(this.locale, this.path, this.line, this.text);
  final String locale;
  final String path;
  final int? line;
  final String? text;
}

/// The key's line in each locale's YAML. A key segment may carry a slang
/// modifier, as in `count(plural)`, and may be written in another case than
/// the generated getter when the project sets slang's `key_case`.
List<LocaleLine> localeLines(Workspace ws, SlangConfig config, String key) {
  final out = <LocaleLine>[];
  for (final MapEntry(key: locale, value: path)
      in config.localeFiles(ws).entries) {
    YamlNode? node;
    try {
      node = loadYamlNode(File('${ws.root}/$path').readAsStringSync());
    } on Exception {
      out.add(LocaleLine(locale, path, null, null));
      continue;
    }
    YamlNode? keyNode;
    for (final segment in key.split('.')) {
      if (node is! YamlMap) {
        keyNode = null;
        break;
      }
      final match = _child(node, segment);
      keyNode = match?.key as YamlNode?;
      node = match?.value;
      if (match == null) break;
    }
    if (keyNode == null) {
      out.add(LocaleLine(locale, path, null, null));
      continue;
    }
    final value = node is YamlScalar ? '${node.value}' : null;
    out.add(LocaleLine(locale, path, keyNode.span.start.line + 1, value));
  }
  return out;
}

MapEntry<Object?, YamlNode>? _child(YamlMap map, String segment) {
  String bare(Object? k) =>
      k is YamlScalar ? '${k.value}'.replaceFirst(RegExp(r'\(.*\)$'), '') : '';
  String loose(String s) => s.replaceAll('_', '').toLowerCase();
  final entries = map.nodes.entries;
  return entries.where((e) => bare(e.key) == segment).firstOrNull ??
      entries.where((e) => loose(bare(e.key)) == loose(segment)).firstOrNull;
}

/// A verb's answer for the getter serving a translation key, preceded by the
/// key's line in each locale.
class TranslationAnswer extends ComposedAnswer {
  TranslationAnswer(this.key, this.locales, this.inner);

  final String key;
  final List<LocaleLine> locales;
  final Answer inner;

  @override
  String get verb => inner.verb;

  @override
  int get exit => inner.exit;

  @override
  List<Answer> get parts => [inner];

  @override
  String get separator => '\n';

  @override
  void write(TextOut out) {
    final missing = locales.where((l) => l.line == null).map((l) => l.locale);
    out.header(
      'translation key $key'
      '${missing.isEmpty ? '' : ', missing in ${missing.join(', ')}'}',
    );
    for (final l in locales) {
      out.header(
        l.line == null
            ? '  ${l.locale.padRight(4)} missing from ${l.path}'
            : '  ${l.locale.padRight(4)} ${l.path}:${l.line}'
                  '${l.text == null ? '' : '  ${_clip(l.text!)}'}',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'key': key,
    'locales': [
      for (final l in locales)
        {'locale': l.locale, 'path': l.path, 'line': l.line, 'text': l.text},
    ],
    ...inner.toJson(),
  };
}

String _clip(String s) {
  final one = s.replaceAll('\n', r'\n');
  return one.length <= 90 ? one : '${one.substring(0, 87)}...';
}

/// Translation keys as `refs` and `show` see them. The index is built on
/// first use and kept while `slang.yaml` reads the same and the generated base
/// file is unchanged; a build that finds nothing is not kept, so a project
/// that adds slang or finishes indexing is picked up on the next query.
class Translations {
  Translations(this._engine);

  final Engine _engine;
  TranslationIndex? _index;

  void filesChanged(Iterable<String> paths) {
    if (_index case final i? when paths.contains(i.config.baseFile)) {
      _index = null;
    }
  }

  /// [body] run on the getter serving the key [query] names, or null when it
  /// names no key.
  Future<Answer?> answer(
    String query,
    Future<Answer> Function(Target target) body,
  ) async {
    final index = await _current();
    final key = index?.keyFor(query);
    if (index == null || key == null) return null;
    final target = targetOf(_engine.analysis, index.keys[key]!);
    if (target == null) return null;
    return TranslationAnswer(
      key,
      localeLines(_engine.workspace, index.config, key),
      await body(target),
    );
  }

  Future<TranslationIndex?> _current() async {
    final config = SlangConfig.read(_engine.workspace);
    if (config == null) return _index = null;
    if (_index case final i? when i.config == config) return i;
    return _index = await TranslationIndex.build(_engine, config);
  }
}
