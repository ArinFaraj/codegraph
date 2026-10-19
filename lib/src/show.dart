// `show <symbol>`: a declaration's signature, its place in the type
// hierarchy, and how it is used. Providers list their readers by role.
import 'package:analyzer/dart/element/element.dart';

import 'classify.dart';
import 'declarations.dart';
import 'engine.dart';
import 'refs.dart';
import 'result.dart';
import 'riverpod.dart';
import 'symbols.dart';

Future<Answer> showSymbol(
  Engine engine,
  String query,
) => engine.withTarget('show', query, (t) async {
  final e = t.element;
  final declared = await declarationOf(engine.analysis, t);
  final subs = e is InterfaceElement ? await engine.subtypes(e) : null;
  final overrides = isInstanceMember(e) ? await engine.overrideSet(e) : null;
  return ShowSymbolAnswer(
    target: t,
    query: query,
    signature: declared?.$1.sig ?? e.displayName,
    doc: declared?.$1.doc,
    members: [
      for (final m in declared?.$2 ?? const <DeclNode>[])
        (engine.sources.lineOf(t.path, m.nameOffset), m.sig),
    ],
    supertypes: e is InterfaceElement
        ? [
            for (final s in e.allSupertypes)
              if (!(s.element.name == 'Object' && s.element.library.isDartCore))
                s.getDisplayString(),
          ]
        : const [],
    subtypes: [
      for (final s in subs?.items ?? const <InterfaceElement>[])
        ?targetOf(engine.analysis, s),
    ],
    overrides: [
      for (final m in overrides?.items ?? const <Element>[])
        if (m != e.nonSynthetic) ?targetOf(engine.analysis, m),
    ],
    truncated: (subs?.truncated ?? false) || (overrides?.truncated ?? false),
    uses: await engine.usesOf(e),
  );
});

class ShowSymbolAnswer extends Answer {
  ShowSymbolAnswer({
    required this.target,
    required this.query,
    required this.signature,
    required this.doc,
    required this.members,
    required this.supertypes,
    required this.subtypes,
    required this.overrides,
    required this.truncated,
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

  /// The rest of a member's override set.
  final List<Target> overrides;

  /// A subtype walk behind [subtypes] or [overrides] stopped early.
  final bool truncated;
  final List<Use> uses;

  bool get _isProvider => isProvider(target.element);
  bool get _isType => target.element is InterfaceElement;
  String? get _partial =>
      truncated ? 'subtype walks stop at ${Engine.subtypeCap}' : null;

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
    if (supertypes.isNotEmpty) {
      out.header('supertypes: ${supertypes.join(', ')}');
    }
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
    if (uses.isNotEmpty) {
      out.footer('every use with its line: codegraph refs $query');
    }
    if (_partial case final p?) out.partial(p);
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
    'partial': ?_partial,
  };
}
