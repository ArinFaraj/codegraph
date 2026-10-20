import 'dart:io';

import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('codegraph_ws_');
    File('${root.path}/pubspec.yaml').writeAsStringSync('name: app\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  List<String> pluginsFor(String options) {
    File('${root.path}/analysis_options.yaml').writeAsStringSync(options);
    return Workspace.find(root.path)!.analyzerPlugins();
  }

  test('top-level plugins are named, dependency overrides are not', () {
    expect(
      pluginsFor('''
plugins:
  riverpod_lint:
    version: ^3.0.0
  house_lints:
    path: ./packages/house_lints
  dependency_overrides:
    analyzer: any
'''),
      ['riverpod_lint', 'house_lints'],
    );
  });

  test('legacy analyzer plugins are named too', () {
    expect(
      pluginsFor('''
analyzer:
  plugins:
    - custom_lint
'''),
      ['custom_lint'],
    );
  });

  test('no plugins, no options file and broken YAML give none', () {
    expect(pluginsFor('linter:\n  rules: []\n'), isEmpty);
    expect(pluginsFor('plugins: [\n'), isEmpty);
    File('${root.path}/analysis_options.yaml').deleteSync();
    expect(Workspace.find(root.path)!.analyzerPlugins(), isEmpty);
  });
}
