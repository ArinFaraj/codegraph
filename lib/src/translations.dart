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
    try {
      final y = loadYaml(file.readAsStringSync());
      if (y is! Map) return null;
      final input = (y['input_directory'] as String?) ?? 'lib/i18n';
      final output = (y['output_directory'] as String?) ?? input;
      final pattern = (y['input_file_pattern'] as String?) ?? '.i18n.json';
      final base = (y['base_locale'] as String?) ?? 'en';
      final name = (y['output_file_name'] as String?) ?? 'strings.g.dart';
      final stem = name.substring(0, name.length - '.g.dart'.length);
      final split = '$output/${stem}_$base.g.dart';
      return SlangConfig(
        input,
        pattern,
        File('${ws.root}/$split').existsSync() ? split : '$output/$name',
        base,
      );
    } on Exception {
      return null;
    }
  }

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

  static Future<TranslationIndex?> build(Engine engine) async {
    final config = SlangConfig.read(engine.workspace);
    if (config == null || !engine.analysis.isAnalyzed(config.baseFile)) {
      return null;
    }
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
class TranslationAnswer extends Answer {
  TranslationAnswer(this.key, this.locales, this.inner);

  final String key;
  final List<LocaleLine> locales;
  final Answer inner;

  @override
  String get verb => inner.verb;

  @override
  int get exit => inner.exit;

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
  String render({required bool asJson, required int? limit}) {
    if (asJson) return super.render(asJson: true, limit: limit);
    final head = TextOut();
    write(head);
    return '${head.build(null)}\n${inner.render(asJson: false, limit: limit)}';
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

/// [body] run on the getter serving the translation key [query] names, or
/// null when it names no key.
Future<Answer?> translationAnswer(
  Engine engine,
  String query,
  Future<Answer> Function(Target target) body,
) async {
  final index = await engine.translations();
  final key = index?.keyFor(query);
  if (index == null || key == null) return null;
  final target = targetOf(engine.analysis, index.keys[key]!);
  if (target == null) return null;
  return TranslationAnswer(
    key,
    localeLines(engine.workspace, index.config, key),
    await body(target),
  );
}
