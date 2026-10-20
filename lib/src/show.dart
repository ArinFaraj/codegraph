// `show <symbol>`: a declaration's source, its place in the type hierarchy,
// and how it is used. Providers list their readers by role. A `show` that
// names a file or directory is answered by show_file.dart.
import 'dart:math';

import 'package:analyzer/dart/element/element.dart';

import 'classify.dart';
import 'declarations.dart';
import 'engine.dart';
import 'kinds.dart';
import 'refs.dart';
import 'result.dart';
import 'riverpod.dart';
import 'show_file.dart';
import 'symbols.dart';

Future<Answer> show(Engine engine, String query) async =>
    await showPath(engine, query) ?? await showSymbol(engine, query);

Future<Answer> showSymbol(
  Engine engine,
  String query,
) => engine.withEachTarget('show', query, (t) async {
  final e = t.element;
  final declared = await declarationOf(engine.analysis, t);
  final subs = e is InterfaceElement ? await engine.subtypes(e) : null;
  final source = declared == null ? null : _source(engine, t.path, declared.$1);
  final overrides = isInstanceMember(e) ? await engine.overrideSet(e) : null;
  return ShowSymbolAnswer(
    target: t,
    query: query,
    signature: declared?.$1.sig ?? e.displayName,
    source: source,
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

/// Source shown in full up to this many lines; longer declarations show the
/// first lines, and types show their members instead.
const sourceLines = 60;

/// The declaration's source lines, numbered.
SourceExcerpt _source(Engine engine, String path, DeclNode d) {
  final (start, end) = sourceSpan(d);
  final first = engine.sources.lineOf(path, start);
  final last = engine.sources.lineOf(path, end);
  return SourceExcerpt(
    first,
    last,
    engine.sources.lines(path, first, min(last, first + sourceLines - 1)),
  );
}

class SourceExcerpt {
  SourceExcerpt(this.first, this.last, this.lines);

  final int first;
  final int last;

  /// At most [sourceLines] lines, starting at [first].
  final List<String> lines;

  bool get complete => first + lines.length - 1 == last;
}

class ShowSymbolAnswer extends Answer {
  ShowSymbolAnswer({
    required this.target,
    required this.query,
    required this.signature,
    required this.source,
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
  final SourceExcerpt? source;
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

  Map<Role, int> get _counts {
    final counts = <Role, int>{};
    for (final u in uses) {
      counts[u.role] = (counts[u.role] ?? 0) + 1;
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => a.key.index.compareTo(b.key.index)),
    );
  }

  @override
  String get verb => 'show';

  @override
  void write(TextOut out) {
    out.header('${target.kind} ${target.qualified}  ${target.location}');
    if (doc != null) out.header('  $doc');
    final src = source;
    final showSource = src != null && (src.complete || !_isType);
    if (showSource) {
      final width = '${src.first + src.lines.length - 1}'.length;
      for (var i = 0; i < src.lines.length; i++) {
        out.header('${'${src.first + i}'.padLeft(width)}  ${src.lines[i]}');
      }
      if (!src.complete) {
        out.header(
          '... ${src.last - src.first + 1 - src.lines.length} more lines, '
          'to line ${src.last}',
        );
      }
    } else {
      out.header('  $signature');
    }
    if (supertypes.isNotEmpty) {
      out.header('supertypes: ${supertypes.join(', ')}');
    }
    if (_isType) {
      out.section('subtypes (${subtypes.length}, transitive):');
      for (final s in subtypes) {
        out.row('  ${s.kind} ${s.qualified}  ${s.location}');
      }
    }
    if (members.isNotEmpty && !showSource) {
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
    if (source case final src?)
      'source': {
        'firstLine': src.first,
        'lastLine': src.last,
        'text': src.lines.join('\n'),
        'complete': src.complete,
      },
    'doc': ?doc,
    'supertypes': supertypes,
    if (_isType) 'subtypes': [for (final s in subtypes) s.toJson()],
    'members': [
      for (final (line, sig) in members) {'line': line, 'signature': sig},
    ],
    'overrides': [for (final o in overrides) o.toJson()],
    'useCounts': {for (final e in _counts.entries) e.key.label: e.value},
    if (_isProvider)
      'readers': [for (final u in uses.where((u) => !u.inTest)) useJson(u)],
    'partial': ?_partial,
  };
}
