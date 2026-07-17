// Shared construction of the analyzer context collection, with environment
// failures made typed and clean - and the one real field case fixed.
//
// A `dart compile exe` binary cannot discover the Dart SDK the analyzer's
// default way: FolderBasedDartSdk resolves relative to the running executable
// (which is the compiled binary, not `dart`) and dies in PathNotFoundException
// before any file is analyzed (verified 2026-07-18). The fix: when NOT running
// under the `dart` VM, discover the SDK from the `dart` binary on PATH and
// pass it as `sdkPath` explicitly. Machines with no `dart` at all still get a
// typed ResolvedAnalysisUnavailable, which `build` (auto policy) converts to
// the zero-setup syntax fallback and explicit resolved surfaces refuse on.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';

class ResolvedAnalysisUnavailable implements Exception {
  ResolvedAnalysisUnavailable(this.cause);
  final Object cause;

  @override
  String toString() =>
      'resolved analysis is unavailable in this environment: $cause. '
      'If codegraph was compiled to a native executable, the analyzer needs a '
      'Dart SDK - install Dart on PATH, or run the pub-activated (JIT) '
      'codegraph instead.';
}

/// Constructs the collection. Under the `dart` VM the analyzer finds the SDK
/// itself; in a native (AOT) binary the SDK is discovered from PATH first.
/// Any construction-time failure maps to [ResolvedAnalysisUnavailable].
AnalysisContextCollection newAnalysisCollection(List<String> includedPaths) {
  final exeName = Uri.file(Platform.resolvedExecutable).pathSegments.last;
  final underVm = exeName == 'dart' || exeName == 'dart.exe';
  final sdkPath = underVm ? null : discoverSdkPath();
  try {
    return AnalysisContextCollection(
      includedPaths: includedPaths,
      sdkPath: sdkPath,
    );
  } catch (e) {
    throw ResolvedAnalysisUnavailable(e);
  }
}

/// SDK root discovered by asking the PATH `dart` where its VM lives
/// (`Platform.resolvedExecutable` from a probe script), then walking
/// `<sdk>/bin/dart` up to the root, verified by the SDK `version` marker.
/// Path-walking the `dart` command itself is NOT reliable - fvm and Flutter
/// ship wrapper SCRIPTS whose resolved location is a checkout root, not a
/// dart-sdk (the real SDK hides at `<flutter>/bin/cache/dart-sdk`). The probe
/// answers correctly for every layout because the running VM knows its own
/// binary. Costs one `dart` startup, only on the native-binary path. Null
/// when `dart` is absent - callers surface the typed error.
String? discoverSdkPath() {
  Directory? tmp;
  try {
    tmp = Directory.systemTemp.createTempSync('codegraph_sdk_probe_');
    final probe = File('${tmp.path}/probe.dart')
      ..writeAsStringSync('import "dart:io";\n'
          'void main() { stdout.write(Platform.resolvedExecutable); }\n');
    final r = Process.runSync('dart', [probe.path]);
    if (r.exitCode != 0) return null;
    final vm = (r.stdout as String).trim();
    if (vm.isEmpty) return null;
    final sdkDir = File(vm).parent.parent.path;
    return File('$sdkDir/version').existsSync() ? sdkDir : null;
  } catch (_) {
    return null;
  } finally {
    try {
      tmp?.deleteSync(recursive: true);
    } catch (_) {}
  }
}
