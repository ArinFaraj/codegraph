import 'package:test/test.dart';

import '../benchmarks/perf.dart' as perf;

void main() {
  test('absolute baseline excludes ratio-only analyzer references', () {
    expect(perf.usesAbsoluteBaseline('rename_analyzer_ms'), isFalse);
    expect(perf.usesAbsoluteBaseline('callers_analyzer_ms'), isFalse);
    expect(perf.usesAbsoluteBaseline('rename_indexed_ms'), isTrue);
    expect(perf.usesAbsoluteBaseline('resolved_build_ms'), isTrue);
  });
}
