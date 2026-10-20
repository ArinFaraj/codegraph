// How many of each problem a file has, so a later look can tell which of its
// problems are new. `check` keys problems by their full identity. An applied
// rename or move keys errors by code only, because the rename itself rewrites
// the messages of errors that name the old identifier.
import 'analysis.dart';

typedef ProblemKey = String Function(Problem p);

String byIdentity(Problem p) => p.identity;

String byCode(Problem p) => p.code;

class ProblemCounts {
  ProblemCounts._(this._counts, this._key);

  factory ProblemCounts.of(Iterable<Problem> problems, ProblemKey key) {
    final counts = <String, int>{};
    for (final p in problems) {
      counts[key(p)] = (counts[key(p)] ?? 0) + 1;
    }
    return ProblemCounts._(counts, key);
  }

  factory ProblemCounts.fromJson(Map<String, dynamic> j) =>
      ProblemCounts._(j.cast<String, int>(), byIdentity);

  static final none = ProblemCounts._(const {}, byIdentity);

  final Map<String, int> _counts;
  final ProblemKey _key;

  bool get isEmpty => _counts.isEmpty;

  Map<String, int> toJson() => _counts;

  /// The problems in [now] beyond what these counts allow for.
  List<Problem> newIn(Iterable<Problem> now) {
    final budget = {..._counts};
    final out = <Problem>[];
    for (final p in now) {
      final left = budget[_key(p)] ?? 0;
      if (left > 0) {
        budget[_key(p)] = left - 1;
      } else {
        out.add(p);
      }
    }
    return out;
  }

  bool sameAs(ProblemCounts other) =>
      _counts.length == other._counts.length &&
      _counts.entries.every((e) => other._counts[e.key] == e.value);
}
