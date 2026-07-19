import 'dart:io';

import 'package:codegraph/src/refactor_index.dart';
import 'package:test/test.dart';

void main() {
  test('package: URIs pass through untouched', () {
    expect(
      portableLibraryUri(Uri.parse('package:foo/bar.dart')),
      'package:foo/bar.dart',
    );
  });

  test('dart: URIs pass through untouched', () {
    expect(portableLibraryUri(Uri.parse('dart:core')), 'dart:core');
  });

  test('file URIs under the package root become root-relative', () {
    final uri = Directory.current.uri.resolve('test/foo_test.dart');
    expect(portableLibraryUri(uri), 'file:test/foo_test.dart');
  });

  test('file URIs outside the package root keep the absolute form', () {
    final uri = Uri.parse('file:///somewhere/else/foo.dart');
    expect(portableLibraryUri(uri), 'file:///somewhere/else/foo.dart');
  });
}
