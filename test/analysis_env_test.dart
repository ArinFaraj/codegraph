// The analyzer collection wrapper must convert construction-time environment
// failures into the typed ResolvedAnalysisUnavailable (callers fall back to
// syntax or refuse cleanly) - never leak an unhandled stack. The field case is
// a native-compiled binary that cannot discover a Dart SDK; the test proxy is
// the analyzer's absolute-path requirement, which fails at the same
// construction boundary.
import 'package:codegraph/src/analysis_env.dart';
import 'package:test/test.dart';

void main() {
  test('construction failure maps to ResolvedAnalysisUnavailable', () {
    expect(() => newAnalysisCollection(['relative/not/absolute.dart']),
        throwsA(isA<ResolvedAnalysisUnavailable>()));
  });

  test('the error message names the native-executable cause and the fix', () {
    try {
      newAnalysisCollection(['relative/not/absolute.dart']);
      fail('expected ResolvedAnalysisUnavailable');
    } on ResolvedAnalysisUnavailable catch (e) {
      expect('$e', contains('native executable'));
      expect('$e', contains('pub-activated'));
    }
  });
}
