// The resolved state one worker keeps warm, and the element queries every
// resolved verb shares. Verbs live in their own files (refs, show, impact,
// rename); [Engine.refresh] runs before each request so answers reflect the
// disk.
import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'check.dart' show Ledger;
import 'classify.dart';
import 'files.dart';
import 'outline.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

/// A list a query stopped filling early, and whether it did.
class Bounded<T> {
  Bounded(this.items, {required this.truncated});
  final List<T> items;
  final bool truncated;
}

class Engine {
  Engine(this.analysis) : sources = SourceCache(analysis.workspace) {
    outline = OutlineIndex.inMemory(workspace, analysis.files, sources.text);
  }

  final Analysis analysis;
  final SourceCache sources;
  late final OutlineIndex outline;

  /// What every file's problems were when last checked; built once the
  /// workspace is indexed, and kept across analyzer restarts.
  Ledger? ledger;

  /// What the most recent [refresh] found changed on disk.
  FileDelta? lastDelta;

  Workspace get workspace => analysis.workspace;

  /// Syncs the analyzer with the disk and drops everything derived from the
  /// files that changed.
  Future<FileDelta> refresh() async {
    final delta = lastDelta = await analysis.sync();
    filesChanged(delta.all);
    return delta;
  }

  void filesChanged(Iterable<String> paths) {
    final list = paths.toList();
    sources.invalidate(list);
    outline.refresh(list, sources.text);
  }

  Future<Resolution> resolve(String query) => resolveSymbol(analysis, query);

  /// Runs [body] on the one declaration [query] names, or answers why there
  /// is not exactly one.
  Future<Answer> withTarget(
    String verb,
    String query,
    Future<Answer> Function(Target target) body,
  ) async => switch (await resolve(query)) {
    Resolved(:final target) => await body(target),
    final Unresolved u => lookupFailure(verb, query, u),
  };

  /// The element and the accessors, variable and getter/setter partners that
  /// share its name, so a property's uses are counted once, completely.
  Set<Element> propertyFamily(Element e) => switch (e) {
    PropertyInducingElement() => {e, ?e.getter, ?e.setter},
    GetterElement() => {e, e.variable, ?e.correspondingSetter},
    SetterElement() => {e, e.variable, ?e.correspondingGetter},
    _ => {e},
  };

  Future<List<Use>> usesOf(Element e) async {
    final sites = <String, Site>{};
    for (final member in propertyFamily(e)) {
      for (final s in await analysis.references(member)) {
        sites.putIfAbsent(s.key, () => s);
      }
    }
    final sorted = sites.values.toList()
      ..sort((a, b) {
        final c = a.path.compareTo(b.path);
        return c != 0 ? c : a.offset.compareTo(b.offset);
      });
    return [for (final s in sorted) classify(s, sources)];
  }

  static const subtypeCap = 500;

  /// Every subtype of [type], transitively, within the workspace.
  Future<Bounded<InterfaceElement>> subtypes(InterfaceElement type) async {
    final out = <InterfaceElement>[];
    final seen = <String>{};
    final queue = [type];
    while (queue.isNotEmpty) {
      for (final s in await analysis.directSubtypes(queue.removeLast())) {
        final at = analysis.locate(s);
        if (at == null || !seen.add('${at.path}:${at.offset}')) continue;
        if (out.length == subtypeCap) return Bounded(out, truncated: true);
        out.add(s);
        queue.add(s);
      }
    }
    return Bounded(out, truncated: false);
  }

  /// Instance members named like [member] across its class hierarchy: the
  /// members it overrides, the ones overriding it, and their siblings
  /// through shared supertypes. Renaming one means renaming all, so the
  /// result says when a subtype list behind it was cut short.
  Future<Bounded<Element>> overrideSet(Element member) async {
    final owner = member.enclosingElement;
    if (!isInstanceMember(member) || owner is! InterfaceElement) {
      return Bounded([member.nonSynthetic], truncated: false);
    }
    final classes = <InterfaceElement>{
      owner,
      for (final t in owner.allSupertypes) t.element,
    };
    var truncated = false;
    for (final c in classes.toList()) {
      if (analysis.locate(c) == null) continue;
      final subs = await subtypes(c);
      truncated |= subs.truncated;
      classes.addAll(subs.items);
    }
    return Bounded(
      {
        for (final c in classes)
          for (final m in [
            ...c.fields,
            ...c.getters,
            ...c.setters,
            ...c.methods,
          ])
            if (m.name == member.name && isInstanceMember(m)) m.nonSynthetic,
      }.toList(),
      truncated: truncated,
    );
  }
}
