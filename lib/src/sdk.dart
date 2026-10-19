import 'dart:io';

/// The Dart SDK the analyzer should resolve against, or null to let the
/// analyzer find it from the running VM.
///
/// A native executable has no SDK of its own, so it asks the `dart` on PATH
/// where its VM lives. Walking up from the `dart` command is not reliable: fvm
/// and Flutter ship wrapper scripts whose location is a checkout, while the
/// real SDK sits in `<flutter>/bin/cache/dart-sdk`.
String? sdkPathForAnalysis() {
  final exe = Uri.file(Platform.resolvedExecutable).pathSegments.last;
  if (exe == 'dart' || exe == 'dart.exe' || exe == 'dartvm') return null;
  return discoverSdkPath();
}

String? discoverSdkPath() {
  Directory? tmp;
  try {
    tmp = Directory.systemTemp.createTempSync('codegraph_sdk_probe_');
    final probe = File('${tmp.path}/probe.dart')
      ..writeAsStringSync(
        'import "dart:io";\n'
        'void main() { stdout.write(Platform.resolvedExecutable); }\n',
      );
    final r = Process.runSync('dart', [probe.path]);
    if (r.exitCode != 0) return null;
    final vm = (r.stdout as String).trim();
    if (vm.isEmpty) return null;
    final sdk = File(vm).parent.parent.path;
    return File('$sdk/version').existsSync() ? sdk : null;
  } catch (_) {
    return null;
  } finally {
    try {
      tmp?.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Version of the SDK at [sdkPath], or of the running VM's SDK.
String? sdkVersion(String? sdkPath) {
  final path = sdkPath ?? File(Platform.resolvedExecutable).parent.parent.path;
  final f = File('$path/version');
  if (!f.existsSync()) return null;
  return f.readAsStringSync().trim();
}
