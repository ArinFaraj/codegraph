import 'dart:io';
import 'dart:isolate';

import 'result.dart';

/// Compiles the currently installed Codegraph package to a real executable.
///
/// `dart pub global activate` installs a shell launcher that runs
/// `dart pub global run` on every invocation. That startup path can cost more
/// than the query itself. The native executable keeps the global package as
/// the update/source channel while removing pub resolution from hot commands.
Future<int> run(List<String> args) async {
  final outputFlag = args.indexOf('--output');
  if (outputFlag >= 0 && outputFlag + 1 >= args.length) {
    stderr.writeln('usage: codegraph install-native [--output <path>]');
    return Exit.usage;
  }
  final home = Platform.environment['HOME'];
  if (outputFlag < 0 && (home == null || home.isEmpty)) {
    stderr.writeln(
      'cannot choose a default install path because HOME is unavailable; '
      'pass --output <path>',
    );
    return Exit.cannotAnalyze;
  }
  final target = File(
    outputFlag >= 0 ? args[outputFlag + 1] : '$home/.local/bin/codegraph',
  ).absolute;
  final packageUri = await Isolate.resolvePackageUri(
    Uri.parse('package:codegraph/src/native_install.dart'),
  );
  if (packageUri == null || packageUri.scheme != 'file') {
    stderr.writeln(
      'cannot locate the installed Codegraph source; run this command through '
      '~/.pub-cache/bin/codegraph after `dart pub global activate`',
    );
    return Exit.cannotAnalyze;
  }
  final source = File.fromUri(packageUri);
  final packageRoot = source.parent.parent.parent;
  final entrypoint = File('${packageRoot.path}/bin/codegraph.dart');
  if (!entrypoint.existsSync()) {
    stderr.writeln('cannot find Codegraph entrypoint at ${entrypoint.path}');
    return Exit.cannotAnalyze;
  }

  target.parent.createSync(recursive: true);
  final temporary = File(
    '${target.path}.install-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  stdout.writeln('compiling native Codegraph to ${target.path}');
  final result = await Process.run('dart', [
    'compile',
    'exe',
    entrypoint.path,
    '-o',
    temporary.path,
  ], workingDirectory: packageRoot.path);
  if (result.stdout.toString().isNotEmpty) stdout.write(result.stdout);
  if (result.stderr.toString().isNotEmpty) stderr.write(result.stderr);
  if (result.exitCode != 0 || !temporary.existsSync()) {
    if (temporary.existsSync()) temporary.deleteSync();
    return result.exitCode == 0 ? Exit.failed : result.exitCode;
  }

  final verification = await Process.run(temporary.path, ['--version']);
  if (verification.exitCode != 0 ||
      !verification.stdout.toString().startsWith('codegraph ')) {
    stderr.writeln(
      'compiled executable failed its version check; not installed',
    );
    temporary.deleteSync();
    return Exit.failed;
  }
  try {
    temporary.renameSync(target.path);
  } on FileSystemException catch (error) {
    stderr.writeln('could not install ${target.path}: $error');
    if (temporary.existsSync()) temporary.deleteSync();
    return Exit.failed;
  }
  stdout.writeln(
    'installed ${verification.stdout.toString().trim()} at ${target.path}',
  );
  return Exit.ok;
}
