/// Set overlap scores for usefulness benchmarks.
class UsefulnessScore {
  UsefulnessScore({
    required this.truth,
    required this.found,
    required this.toolCalls,
    required this.outputChars,
    this.wallMs,
    this.notes = const [],
  })  : intersection = truth.intersection(found),
        falsePositives = found.difference(truth),
        misses = truth.difference(found);

  final Set<String> truth;
  final Set<String> found;
  final int toolCalls;

  /// Bytes of tool output an agent would ingest - proxy for context spent.
  /// Codegraph: raw CLI stdout length. Grep: matched lines joined, the shape
  /// `rg -l` actually prints. (Was line-count, which was always 1 for the
  /// single-line JSON codegraph emits - a broken comparison.)
  final int outputChars;
  final int? wallMs;
  final List<String> notes;

  final Set<String> intersection;
  final Set<String> falsePositives;
  final Set<String> misses;

  double get recall => truth.isEmpty
      ? (found.isEmpty ? 1.0 : 0.0)
      : intersection.length / truth.length;

  double get precision => found.isEmpty
      ? (truth.isEmpty ? 1.0 : 0.0)
      : intersection.length / found.length;

  double get f1 {
    final r = recall;
    final p = precision;
    if (r + p == 0) return 0;
    return 2 * r * p / (r + p);
  }

  Map<String, dynamic> toJson(String arm) => {
        'arm': arm,
        'recall': (recall * 1000).round() / 1000,
        'precision': (precision * 1000).round() / 1000,
        'f1': (f1 * 1000).round() / 1000,
        'truthCount': truth.length,
        'foundCount': found.length,
        'intersectionCount': intersection.length,
        'falsePositives': falsePositives.toList()..sort(),
        'misses': misses.toList()..sort(),
        'toolCalls': toolCalls,
        'outputChars': outputChars,
        if (wallMs != null) 'wallMs': wallMs,
        if (notes.isNotEmpty) 'notes': notes,
      };
}
