// `codegraph lint` — turns the host's architecture prose into a CI gate.
// A rule fires ONLY on a fact the graph states (an import edge, a role); no
// heuristics. Config = `codegraph.json` at the host package root (stdlib
// jsonDecode, zero new deps). Stage 1: cross-feature-import + layer-order.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'freshness.dart';
import 'model.dart';

const _configPath = 'codegraph.json';
const _baselinePath = 'docs/maps/lint-baseline.json';

/// Malformed `codegraph.json`. Thrown by [LintConfig.load] instead of
/// exit()ing so in-process callers (`diff`'s lint reuse, tests) can catch;
/// `run()` turns it back into the same stderr message + exit 64 the CLI
/// always had.
class LintConfigException implements Exception {
  LintConfigException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A single architecture-rule violation. [from] is the src file id sans
/// `file:`; [to] is the dst file id sans prefix OR a rule-specific detail
/// string. Sorted deterministically by `rule|from|to|line`.
class Violation {
  Violation(this.rule, this.from, this.to, {this.line});
  final String rule;
  final String from;
  final String to;
  final int? line;

  String get _sortKey => '$rule|$from|$to|${line ?? -1}';
  int compareTo(Violation o) => _sortKey.compareTo(o._sortKey);

  /// Baseline identity — deliberately EXCLUDES [line] so moving a violating
  /// line never churns the baseline. Two violations with the same
  /// `rule|from|to` are the same baselined fact.
  String get identity => '$rule|$from|$to';
}

/// Lint configuration, loaded from `codegraph.json` (absent → [defaults]).
class LintConfig {
  LintConfig({
    required this.features,
    required this.crossFeatureAllow,
    required this.layersForbid,
    required this.bannedProviderKinds,
    required this.providerHomes,
  });

  LintConfig.defaults()
      : features = const ['lib/features/'],
        crossFeatureAllow = const [],
        layersForbid = const [
          'repository -> view',
          'repository -> widget',
          'repository -> controller',
          'state/model -> view',
          'state/model -> widget',
          'state/model -> controller',
        ],
        bannedProviderKinds = const [],
        providerHomes = null;

  factory LintConfig.fromJson(Map<String, dynamic> j) {
    List<String> strList(Object? v) =>
        (v as List?)?.map((e) => e.toString()).toList() ?? const [];
    // A `features` prefix without a trailing `/` both disables the rule (every
    // real `rest` starts with `/` → null unit) and can straddle sibling dirs
    // (`lib/featuresX/` vs `lib/featuresY/`). Normalizing to end with `/` makes
    // `_unitUnder`'s `startsWith` segment-safe.
    String withSlash(String p) => p.endsWith('/') ? p : '$p/';
    // Allow pairs are matched by exact string, so spacing variants
    // (`a->b`, `a  ->  b`) silently miss. Canonicalize to `a -> b`; drop
    // entries without a `->`.
    List<String> canonPairs(List<String> raw) {
      final out = <String>[];
      for (final s in raw) {
        final i = s.indexOf('->');
        if (i < 0) continue;
        out.add('${s.substring(0, i).trim()} -> ${s.substring(i + 2).trim()}');
      }
      return out;
    }

    final d = LintConfig.defaults();
    return LintConfig(
      features: j.containsKey('features')
          ? strList(j['features']).map(withSlash).toList()
          : d.features,
      crossFeatureAllow: j.containsKey('crossFeatureAllow')
          ? canonPairs(strList(j['crossFeatureAllow']))
          : d.crossFeatureAllow,
      layersForbid: j.containsKey('layersForbid')
          ? strList(j['layersForbid'])
          : d.layersForbid,
      bannedProviderKinds: j.containsKey('banned_provider_kinds')
          ? strList(j['banned_provider_kinds'])
          : d.bannedProviderKinds,
      // Absent key = rule OFF (null); present = the (possibly empty) list.
      providerHomes:
          j.containsKey('provider_homes') ? strList(j['provider_homes']) : null,
    );
  }

  final List<String> features;
  final List<String> crossFeatureAllow;
  final List<String> layersForbid;
  final List<String> bannedProviderKinds;

  /// Roles a provider-declaring file is allowed to have. `null` = rule OFF
  /// (never-guess: an unset home list means "no opinion", not "empty allow").
  final List<String>? providerHomes;

  static const _knownKeys = {
    'features',
    'crossFeatureAllow',
    'layersForbid',
    'banned_provider_kinds',
    'provider_homes',
    'publishedPackages',
  };

  /// Loads [_configPath] from the host root. Absent → defaults. Unknown keys →
  /// one stderr warning, then ignored (forward-compat). Malformed JSON →
  /// throws [LintConfigException] (run() maps it to message + exit 64).
  static LintConfig load([String path = _configPath]) {
    final f = File(path);
    if (!f.existsSync()) return LintConfig.defaults();
    final Object? decoded;
    try {
      decoded = jsonDecode(f.readAsStringSync());
    } on FormatException catch (e) {
      throw LintConfigException('error: $path is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw LintConfigException('error: $path must be a JSON object');
    }
    final unknown = decoded.keys.where((k) => !_knownKeys.contains(k)).toList();
    if (unknown.isNotEmpty) {
      stderr.writeln('warning: unknown codegraph.json key(s): '
          '${unknown.join(', ')}');
    }
    return LintConfig.fromJson(decoded);
  }
}

/// The immediate subdir of a `file:`-prefixed id under [prefix], or null when
/// the file sits directly under the prefix (no unit — never-guess).
String? _unitUnder(String fileId, String prefix) {
  final path = fileId.replaceFirst('file:', '');
  if (!path.startsWith(prefix)) return null;
  final rest = path.substring(prefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null; // directly under the prefix → no unit
  return rest.substring(0, slash);
}

/// Rule 1: an `imports` edge between two DIFFERENT units of the same feature
/// prefix, unless the `"fromUnit -> toUnit"` pair is allow-listed.
List<Violation> _crossFeatureImport(Graph g, LintConfig c) {
  final out = <Violation>[];
  final allow = c.crossFeatureAllow.toSet();
  for (final e in g.edges) {
    if (e.rel != 'imports') continue;
    for (final prefix in c.features) {
      final from = _unitUnder(e.src, prefix);
      final to = _unitUnder(e.dst, prefix);
      if (from == null || to == null || from == to) continue;
      if (allow.contains('$from -> $to')) continue;
      out.add(Violation(
        'cross-feature-import',
        bare(e.src),
        bare(e.dst),
      ));
    }
  }
  return out;
}

/// Rule 2: an `imports` edge whose `"srcRole -> dstRole"` is in `layersForbid`.
/// A missing/`misc` role never matches a forbid pair (never-guess).
List<Violation> _layerOrder(Graph g, LintConfig c) {
  final out = <Violation>[];
  final forbid = c.layersForbid.toSet();
  for (final e in g.edges) {
    if (e.rel != 'imports') continue;
    final srcRole = g.byId[e.src]?.role;
    final dstRole = g.byId[e.dst]?.role;
    if (srcRole == null || dstRole == null) continue;
    if (forbid.contains('$srcRole -> $dstRole')) {
      out.add(Violation(
        'layer-order',
        bare(e.src),
        bare(e.dst),
        line: e.line,
      ));
    }
  }
  return out;
}

/// Rule 3: a provider node whose declared kind is in `bannedProviderKinds`.
/// Empty config list → no violations (never-guess: nothing banned by default).
List<Violation> _bannedProviderKind(Graph g, LintConfig c) {
  final out = <Violation>[];
  if (c.bannedProviderKinds.isEmpty) return out;
  final banned = c.bannedProviderKinds.toSet();
  for (final n in g.nodes) {
    if (!n.isProvider) continue;
    final kind = n.providerType;
    final where = n.declaredIn;
    if (kind == null || where == null || !banned.contains(kind)) continue;
    // Include the provider NAME so N same-kind providers in one file don't
    // collapse to one baseline identity (which would mask later additions).
    out.add(Violation('banned-provider-kind', where, '${n.name}: $kind',
        line: n.line));
  }
  return out;
}

/// Rule 4: a `declares` edge whose src file's role is NOT in `providerHomes`.
/// `providerHomes == null` → rule entirely off (never-guess: unset = no opinion).
List<Violation> _providerPlacement(Graph g, LintConfig c) {
  final out = <Violation>[];
  final homes = c.providerHomes;
  if (homes == null) return out;
  final allowed = homes.toSet();
  for (final e in g.edges) {
    if (e.rel != 'declares') continue;
    final role = g.byId[e.src]?.role;
    if (role == null || allowed.contains(role)) continue;
    final name = e.dst.startsWith('provider:')
        ? e.dst.substring('provider:'.length)
        : bare(e.dst);
    out.add(Violation(
      'provider-placement',
      bare(e.src),
      '$name ($role)',
      line: e.line,
    ));
  }
  return out;
}

/// All lint rules, run in registration order (output is re-sorted anyway).
const _rules = <List<Violation> Function(Graph, LintConfig)>[
  _crossFeatureImport,
  _layerOrder,
  _bannedProviderKind,
  _providerPlacement,
];

/// Writes the SORTED, de-duplicated set of current violation identities to
/// [_baselinePath] as a deterministic JSON object (2-space indent, trailing
/// newline). Byte-identical for identical input — no timestamps, sorted, and
/// the identity set is a `SplayTreeSet`-free sorted `List` (no set-iteration
/// leakage). Returns the number of identities written.
int _writeBaseline(List<Violation> violations) {
  final identities = violations.map((v) => v.identity).toSet().toList()..sort();
  final json = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'violations': identities,
  });
  File(_baselinePath)
    ..createSync(recursive: true)
    ..writeAsStringSync('$json\n');
  return identities.length;
}

/// Loads the baselined identity set from [_baselinePath], or null when absent.
/// A malformed baseline is FATAL (message + exit 64), never silently treated as
/// empty — that would make every violation fire as "new".
Set<String>? _loadBaseline() {
  final f = File(_baselinePath);
  if (!f.existsSync()) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(f.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('error: $_baselinePath is not valid JSON: ${e.message}');
    exit(64);
  }
  final list = decoded is Map ? decoded['violations'] : null;
  if (list is! List) {
    stderr.writeln(
        'error: $_baselinePath malformed (expected {version, violations})');
    exit(64);
  }
  return list.map((e) => e.toString()).toSet();
}

/// Runs every rule against [graph] (config loaded from `codegraph.json`),
/// sorted deterministically. The full set, before baseline partition.
List<Violation> _allViolations(Graph graph) {
  final config = LintConfig.load();
  final all = <Violation>[];
  for (final rule in _rules) {
    all.addAll(rule(graph, config));
  }
  all.sort((a, b) => a.compareTo(b));
  return all;
}

/// Runs every rule against [graph] and returns only the NEW (non-baselined)
/// violations — the same list `run()` acts on to decide its exit code.
/// Public so other verbs (`diff`) can reuse the lint pass without shelling
/// out to the CLI.
List<Violation> newViolations(Graph graph) {
  final all = _allViolations(graph);
  final baseline = _loadBaseline();
  return baseline == null
      ? all
      : all.where((v) => !baseline.contains(v.identity)).toList();
}

/// `int run(List<String> args)` — `lint [--json] [--budget N] [--write-baseline]`.
/// Exit: 0 clean-or-all-baselined, 1 new violations, 64 malformed
/// codegraph.json, 66 no graph.
int run(List<String> args) {
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  final writeBaseline = args.contains('--write-baseline');

  final graph = loadFresh();
  if (graph == null) return 66;

  final List<Violation> all;
  try {
    all = _allViolations(graph);
  } on LintConfigException catch (e) {
    stderr.writeln(e.message);
    return 64;
  }

  if (writeBaseline) {
    final n = _writeBaseline(all);
    stdout.writeln('lint: wrote baseline ($n) -> $_baselinePath');
    return 0;
  }

  // Partition against the baseline (if any). NEW = not baselined; those are the
  // actionable violations that decide the exit code. STALE = baselined but no
  // longer present (fixed) — reported as good news, never affects exit code.
  final baseline = _loadBaseline();
  final violations = baseline == null
      ? all
      : all.where((v) => !baseline.contains(v.identity)).toList();
  final baselinedCount = all.length - violations.length;
  final currentIds = all.map((v) => v.identity).toSet();
  final stale = baseline == null
      ? const <String>[]
      : (baseline.difference(currentIds).toList()..sort());

  final counts = <String, int>{};
  for (final v in violations) {
    counts[v.rule] = (counts[v.rule] ?? 0) + 1;
  }

  if (asJson) {
    final remaining = Budget(budget);
    final shown = remaining.take(violations);
    stdout.writeln(jsonEncode({
      'verb': 'lint',
      'violations': shown
          .map((v) => {
                'rule': v.rule,
                'from': v.from,
                'to': v.to,
                if (v.line != null) 'line': v.line,
              })
          .toList(),
      'counts': counts,
      'baselined': baselinedCount,
      'stale': stale.length,
      'ok': violations.isEmpty,
      if (remaining.truncated) 'truncated': true,
    }));
    return violations.isEmpty ? 0 : 1;
  }

  if (violations.isEmpty) {
    stdout.writeln(baselinedCount > 0
        ? 'lint: clean ($baselinedCount baselined)'
        : 'lint: clean (no violations)');
    if (stale.isNotEmpty) {
      stdout.writeln('note: stale baseline entries (${stale.length}) — '
          'rerun: codegraph lint --write-baseline');
    }
    return 0;
  }

  final out = <String>[];
  // Sections in a stable order (the rule ids, sorted).
  final ruleIds = counts.keys.toList()..sort();
  for (final id in ruleIds) {
    out.add('$id (${counts[id]}):');
    for (final v in violations.where((v) => v.rule == id)) {
      out.add(v.line != null
          ? '  ${v.from} -> ${v.to} (${v.from}:${v.line})'
          : '  ${v.from} -> ${v.to}');
    }
    out.add('');
  }
  if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
  emit(out, budget, hint: 'raise --budget N');
  if (stale.isNotEmpty) {
    stdout.writeln('note: stale baseline entries (${stale.length}) — '
        'rerun: codegraph lint --write-baseline');
  }
  return 1;
}
