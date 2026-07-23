// Binary version + scaffolding-skew comparison, shared by bin/, doctor, and
// passport so the version string and the compare logic live in exactly one
// place.

/// This binary's version. The single source of truth; `bin/codegraph.dart`
/// re-exports it so the CLI banner and the stamp written by `init`/`upgrade`
/// can never drift from what the skew check reads.
const binaryVersion = '3.7.0';

/// Skew of the installed scaffolding vs the running binary. `scaffold` is the
/// stamp read back from the host (null when absent/unparseable).
enum ScaffoldSkew { current, behind, unknown }

/// Compares dotted-int versions (`vX.Y.Z` or `X.Y.Z`). Never-guess: a null,
/// non-numeric, or otherwise unparseable [scaffold] is [ScaffoldSkew.unknown]
/// (treated as needing an upgrade), never assumed current.
ScaffoldSkew skewOf(String? scaffold, String binary) {
  if (scaffold == null) return ScaffoldSkew.unknown;
  final s = _parse(scaffold);
  final b = _parse(binary);
  if (s == null || b == null) return ScaffoldSkew.unknown;
  // Compare MAJOR+MINOR only — a pure-fix PATCH release doesn't change the
  // scaffolding (skill/CLAUDE block/verbs), so nagging every host to re-upgrade
  // on every patch was needless churn. New verbs / scaffolding changes ship as
  // a minor bump (per semver), which this still catches.
  for (var i = 0; i < 2; i++) {
    if (s[i] < b[i]) return ScaffoldSkew.behind;
    if (s[i] > b[i]) return ScaffoldSkew.current; // ahead → don't nag
  }
  return ScaffoldSkew.current;
}

/// Parses `vX.Y.Z` / `X.Y.Z` into `[X, Y, Z]`, dropping any `-suffix` on the
/// patch. Returns null on any parse failure (never-guess).
List<int>? _parse(String v) {
  var s = v.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final parts = s.split('.');
  if (parts.length < 3) return null;
  final out = <int>[];
  for (var i = 0; i < 3; i++) {
    final head = RegExp(r'^\d+').firstMatch(parts[i])?.group(0);
    if (head == null) return null;
    out.add(int.parse(head));
  }
  return out;
}
