import 'package:analyzer/dart/element/element.dart';

import 'classify.dart';
import 'engine.dart';
import 'result.dart';
import 'riverpod.dart';
import 'symbols.dart';

class RefsAnswer extends Answer {
  RefsAnswer(this.target, this.uses, this.analyzedFiles);

  final Target target;
  final List<Use> uses;
  final int analyzedFiles;

  @override
  String get verb => 'refs';

  @override
  void write(TextOut out) {
    final files = uses.map((u) => u.path).toSet();
    final tests = uses.where((u) => u.inTest).map((u) => u.path).toSet().length;
    out.header(
      'refs ${target.qualified} (${target.kind}, ${target.location}): '
      '${plural(uses.length, 'use')} in ${plural(files.length, 'file')}'
      '${tests > 0 ? ' ($tests in tests)' : ''}',
    );
    if (uses.isEmpty)
      out.footer('no uses in ${plural(analyzedFiles, 'analyzed file')}');
    writeUses(out, uses, withSource: true);
  }

  @override
  Map<String, Object?> toJson() => {
    'target': target.toJson(),
    'uses': [for (final u in uses) useJson(u)],
  };
}

Map<String, Object?> useJson(Use u) => {
  'path': u.path,
  'line': u.line,
  'role': u.role,
  'test': u.inTest,
};

/// Writes [uses] grouped by role, library code before tests.
void writeUses(TextOut out, List<Use> uses, {required bool withSource}) {
  for (final ((inTest, role), group) in groupByRole(uses)) {
    out.section('${inTest ? 'tests, ' : ''}$role (${group.length}):');
    for (final u in group) {
      out.row(
        withSource ? '  ${u.location}  ${_clip(u.source)}' : '  ${u.location}',
      );
    }
  }
}

class ShowSymbolAnswer extends Answer {
  ShowSymbolAnswer({
    required this.target,
    required this.query,
    required this.signature,
    required this.doc,
    required this.members,
    required this.supertypes,
    required this.subtypes,
    required this.subtypesTruncated,
    required this.overrides,
    required this.uses,
  });

  final Target target;
  final String query;
  final String signature;
  final String? doc;

  /// Line and signature of each member, for types.
  final List<(int, String)> members;
  final List<String> supertypes;
  final List<Target> subtypes;
  final bool subtypesTruncated;

  /// The rest of a member's override set.
  final List<Target> overrides;
  final List<Use> uses;

  bool get _isProvider => isProvider(target.element);
  bool get _isType => target.element is InterfaceElement;

  Map<String, int> get _counts {
    final counts = <String, int>{};
    for (final u in uses) {
      counts[u.role] = (counts[u.role] ?? 0) + 1;
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => roleRank(a.key).compareTo(roleRank(b.key))),
    );
  }

  @override
  String get verb => 'show';

  @override
  void write(TextOut out) {
    out.header('${target.kind} ${target.qualified}  ${target.location}');
    out.header('  $signature');
    if (doc != null) out.header('  $doc');
    if (supertypes.isNotEmpty)
      out.header('supertypes: ${supertypes.join(', ')}');
    if (_isType) {
      out.section('subtypes (${subtypes.length}, transitive):');
      for (final s in subtypes) {
        out.row('  ${s.kind} ${s.qualified}  ${s.location}');
      }
    }
    if (members.isNotEmpty) {
      out.section('members:');
      for (final (line, sig) in members) {
        out.row('  $line: $sig');
      }
    }
    if (overrides.isNotEmpty) {
      out.section(
        'same member elsewhere in the hierarchy (overrides and overridden):',
      );
      for (final o in overrides) {
        out.row('  ${o.qualified}  ${o.location}');
      }
    }
    if (_isProvider) {
      writeUses(out, uses.where((u) => !u.inTest).toList(), withSource: false);
    }
    final summary = _counts.entries
        .map((e) => '${e.key} ${e.value}')
        .join(', ');
    out.footer(
      'uses: ${plural(uses.length, 'use')} in '
      '${plural(uses.map((u) => u.path).toSet().length, 'file')}'
      '${summary.isEmpty ? '' : ' ($summary)'}',
    );
    if (uses.isNotEmpty)
      out.footer('every use with its line: codegraph refs $query');
    if (subtypesTruncated) out.partial('subtypes stop at ${Engine.subtypeCap}');
  }

  @override
  Map<String, Object?> toJson() => {
    'target': target.toJson(),
    'signature': signature,
    'doc': ?doc,
    'supertypes': supertypes,
    if (_isType) 'subtypes': [for (final s in subtypes) s.toJson()],
    'members': [
      for (final (line, sig) in members) {'line': line, 'signature': sig},
    ],
    'overrides': [for (final o in overrides) o.toJson()],
    'useCounts': _counts,
    if (_isProvider)
      'readers': [for (final u in uses.where((u) => !u.inTest)) useJson(u)],
    if (subtypesTruncated) 'partial': 'subtypes stop at ${Engine.subtypeCap}',
  };
}

class ImpactAnswer extends Answer {
  ImpactAnswer({
    required this.title,
    required this.changed,
    required this.seeds,
    required this.notes,
    required this.directUses,
    required this.direct,
    required this.secondStep,
    required this.tests,
    required this.publishable,
    required this.truncatedDependents,
  });

  final String title;
  final bool changed;
  final List<Target> seeds;
  final List<String> notes;
  final int directUses;

  /// Files outside tests that use a seed, with the seeds they use.
  final Map<String, Set<String>> direct;

  /// Files outside tests reached through a dependent, with the dependents.
  final Map<String, Set<String>> secondStep;
  final List<String> tests;
  final List<String> publishable;

  /// How many dependents there were, when the second step stopped early.
  final int? truncatedDependents;

  String? get _partial => truncatedDependents == null
      ? null
      : 'second step limited to the first ${Engine.secondStepCap} dependents '
            'of $truncatedDependents';

  @override
  String get verb => 'impact';

  @override
  void write(TextOut out) {
    out.header(title);
    out.header(
      '${plural(seeds.length, 'declaration')}${changed ? ' changed' : ''}; '
      '${plural(directUses, 'direct use')}; '
      '${plural({...direct.keys, ...secondStep.keys}.length, 'file')} outside tests and '
      '${plural(tests.length, 'test file')} reached within two steps',
    );
    for (final n in notes) {
      out.header('  $n');
    }
    out.section('uses it directly (${direct.length}):');
    for (final e in direct.entries) {
      out.row('  ${e.key}  (${e.value.take(3).join(', ')})');
    }
    out.section('one step further (${secondStep.length}):');
    for (final e in secondStep.entries) {
      out.row('  ${e.key}  (via ${e.value.take(3).join(', ')})');
    }
    out.section('tests that reference it within two steps (${tests.length}):');
    for (final p in tests) {
      out.row('  $p');
    }
    if (publishable.isNotEmpty) {
      out.footer('crosses publishable packages: ${publishable.join(', ')}');
    }
    if (_partial case final p?) out.partial(p);
  }

  @override
  Map<String, Object?> toJson() => {
    'seeds': [for (final s in seeds) s.toJson()],
    'notes': notes,
    'directUses': directUses,
    'direct': {for (final e in direct.entries) e.key: e.value.toList()},
    'secondStep': {for (final e in secondStep.entries) e.key: e.value.toList()},
    'tests': tests,
    'publishable': publishable,
    'partial': ?_partial,
  };
}

String _clip(String s) => s.length <= 110 ? s : '${s.substring(0, 107)}...';
