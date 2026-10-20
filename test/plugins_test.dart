import 'dart:io';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/check.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/workspace.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  test('check --all names the plugins the analysis options enable, includes '
      'applied', () async {
    final root = writeFixture();
    File('${root.path}/analysis_options.yaml').writeAsStringSync('''
include: shared_options.yaml
analyzer:
  exclude:
    - vendor/**
''');
    File('${root.path}/shared_options.yaml').writeAsStringSync('''
plugins:
  house_lints:
    path: ./packages/house_lints
''');
    initGit(root);
    final analysis = await Analysis.open(
      Workspace.find(root.path)!,
      byteStore: '${root.path}.store',
    );
    addTearDown(() async {
      await analysis.dispose();
      root.deleteSync(recursive: true);
      Directory('${root.path}.store').deleteSync(recursive: true);
    });
    await analysis.warmUp();
    final a = await checkAll(Engine(analysis));
    expect(
      a.render(asJson: false, limit: null),
      endsWith(
        'not run here: analyzer plugins house_lints; dart analyze runs '
        'them',
      ),
    );
  });
}
