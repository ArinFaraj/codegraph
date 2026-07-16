import 'dart:io';

const conventionalTestDirectoryNames = [
  'test',
  'integration_test',
  'patrol_test',
];

/// Conventional test roots belonging to the host and every local package
/// represented by [libraryPaths]. Inputs may be `.../lib` roots or individual
/// `.../lib/file.dart` paths. Output is normalized, unique, and deterministic.
List<String> workspaceTestRoots(Iterable<String> libraryPaths) {
  final packageRoots = <String>{'.'};
  for (var path in libraryPaths) {
    path = path.replaceAll('\\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path == 'lib' || path.startsWith('lib/')) continue;
    final marker = path.indexOf('/lib/');
    if (marker > 0) {
      packageRoots.add(path.substring(0, marker));
    } else if (path.endsWith('/lib')) {
      packageRoots.add(path.substring(0, path.length - 4));
    }
  }
  final sorted = packageRoots.toList()..sort();
  return [
    for (final root in sorted)
      for (final testDir in conventionalTestDirectoryNames)
        root == '.' ? testDir : '$root/$testDir',
  ];
}

Iterable<File> dartFilesUnderTestRoots(Iterable<String> roots) sync* {
  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    final files = directory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    yield* files;
  }
}
