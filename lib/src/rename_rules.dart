// When a rename is refused, and why: each rule names one way renaming could
// break code codegraph cannot see or change.
import 'dart:async';

import 'package:analyzer/dart/element/element.dart';

import 'engine.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

enum RefusalKind {
  /// Renaming could break code codegraph cannot see or change.
  unsafe('UNSAFE'),

  /// codegraph does not compute this kind of rename yet.
  unsupported('UNSUPPORTED');

  const RefusalKind(this.label);
  final String label;
}

class Refusal {
  Refusal(this.kind, this.reason, [this.details = const []]);
  final RefusalKind kind;
  final String reason;
  final List<String> details;
}

class RefusalAnswer extends Answer {
  RefusalAnswer(this.refusal);
  final Refusal refusal;

  @override
  String get verb => 'rename';

  @override
  int get exit => Exit.refused;

  @override
  void write(TextOut out) {
    out.header('${refusal.kind.label}: ${refusal.reason}');
    for (final d in refusal.details) {
      out.row('  $d');
    }
    if (refusal.kind == RefusalKind.unsupported) {
      out.footer(
        'codegraph cannot compute this rename yet. Renaming by hand is fine; '
        'run `codegraph check` afterwards.',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'refused': {
      'kind': refusal.kind.label,
      'reason': refusal.reason,
      'details': refusal.details,
    },
  };
}

/// What every refusal rule looks at.
class RenameCandidate {
  RenameCandidate(
    this.engine,
    this.element,
    this.target,
    this.members,
    this.newName,
  );

  final Engine engine;
  final Element element;
  final Target target;

  /// The override set, with whether a subtype walk behind it stopped early.
  final Bounded<Element> members;
  final String newName;

  String get oldName => element.name!;
}

typedef _Rule = FutureOr<Refusal?> Function(RenameCandidate c);

/// Why renaming [c] is refused, or null when it is safe. Each rule names one
/// way a rename could break code codegraph cannot see or change; the first
/// that applies refuses it.
Future<Refusal?> refusalOf(RenameCandidate c) async {
  for (final rule in _rules) {
    if (await rule(c) case final refusal?) return refusal;
  }
  return null;
}

const List<_Rule> _rules = [
  _privacyChange,
  _incompleteHierarchy,
  _overridesOutside,
  _codeGeneration,
  _publishedApi,
  _dynamicUses,
  _collision,
];

Refusal? _privacyChange(RenameCandidate c) {
  final e = c.element;
  if (e.isPrivate == c.newName.startsWith('_') ||
      e is FormalParameterElement ||
      e is LocalVariableElement) {
    return null;
  }
  return Refusal(
    RefusalKind.unsafe,
    'renaming ${c.target.qualified} to ${c.newName} changes its library privacy',
  );
}

Refusal? _incompleteHierarchy(RenameCandidate c) => c.members.truncated
    ? Refusal(
        RefusalKind.unsafe,
        'the class hierarchy around ${c.target.qualified} has more than '
        '${Engine.subtypeCap} subtypes, so its override set may be incomplete',
      )
    : null;

Refusal? _overridesOutside(RenameCandidate c) {
  final analysis = c.engine.analysis;
  for (final m in c.members.items) {
    if (analysis.locate(m) == null) {
      return Refusal(
        RefusalKind.unsafe,
        '${c.target.qualified} overrides or is overridden by '
        '${m.enclosingElement?.displayName ?? '?'}.${c.oldName}, declared '
        'outside the workspace (${analysis.sourceOf(m)})',
      );
    }
  }
  return null;
}

Refusal? _codeGeneration(RenameCandidate c) {
  for (final m in {c.element, ...c.members.items}) {
    if (_codegenAnnotation(m) case (final on, final name)?) {
      return Refusal(
        RefusalKind.unsafe,
        '$on is annotated @$name: generated code and anything it serializes '
        'derive names from this declaration. Rename by hand, rerun '
        'build_runner, then check stored and wire formats',
      );
    }
  }
  return null;
}

Refusal? _publishedApi(RenameCandidate c) {
  final root = _publishedRoot(c.engine.workspace, c.element, c.target);
  return root == null
      ? null
      : Refusal(
          RefusalKind.unsafe,
          '${c.target.qualified} is public API of $root, whose pubspec does '
          'not say publish_to: none, so consumers outside this repository may '
          'use it',
        );
}

Future<Refusal?> _dynamicUses(RenameCandidate c) async {
  final e = c.element;
  if (!isInstanceMember(e) && e.enclosingElement is! ExtensionElement) {
    return null;
  }
  final uses = await c.engine.analysis.unresolvedMemberReferences(c.oldName);
  if (uses.isEmpty) return null;
  return Refusal(
    RefusalKind.unsafe,
    '${plural(uses.length, 'call')} to .${c.oldName} could not be resolved '
    'to a declaration (dynamic receivers or missing types); they may be uses '
    'of this member',
    [
      for (final s in uses.take(10))
        '${s.path}:${c.engine.sources.lineOf(s.path, s.offset)}',
    ],
  );
}

const _codegenAnnotations = {
  'riverpod',
  'Riverpod',
  'freezed',
  'Freezed',
  'unfreezed',
  'JsonSerializable',
  'JsonEnum',
  'HiveType',
  'HiveField',
  'RestApi',
  'injectable',
  'Injectable',
  'singleton',
  'lazySingleton',
  'TypedGoRoute',
  'TypedShellRoute',
  'CopyWith',
  'MappableClass',
};

/// The declaration carrying a code generation annotation, [e] or its owner.
(String, String)? _codegenAnnotation(Element e) {
  for (final candidate in [e, e.enclosingElement]) {
    if (candidate == null) continue;
    for (final a in candidate.metadata.annotations) {
      final ae = a.element;
      final name = ae is ConstructorElement
          ? ae.enclosingElement.name
          : ae?.name;
      if (name != null && _codegenAnnotations.contains(name)) {
        return (candidate == e ? 'it' : candidate.displayName, name);
      }
    }
  }
  return null;
}

/// The publishable package [e] is public API of, or null.
String? _publishedRoot(Workspace ws, Element e, Target target) {
  final owner = e.enclosingElement;
  if (e.isPrivate ||
      (owner != null && owner is! LibraryElement && owner.isPrivate) ||
      e is LocalVariableElement ||
      e is LocalFunctionElement ||
      (e is FormalParameterElement && !e.isNamed)) {
    return null;
  }
  for (final root in ws.publishablePackageRoots().map(ws.relative)) {
    if (target.path.startsWith('$root/lib/')) return root;
  }
  return null;
}

Refusal? _collision(RenameCandidate c) {
  final e = c.element;
  for (final o in {
    for (final m in {e, ...c.members.items}) ?m.enclosingElement,
  }) {
    if (o is InstanceElement && e is! FormalParameterElement) {
      final members = [...o.fields, ...o.getters, ...o.setters, ...o.methods];
      if (members.any((m) => m.name == c.newName)) {
        return Refusal(
          RefusalKind.unsafe,
          '${o.displayName} already has a member named ${c.newName}',
        );
      }
    }
    if (o is LibraryElement && o.children.any((x) => x.name == c.newName)) {
      return Refusal(
        RefusalKind.unsafe,
        '${c.target.path} already declares a top-level ${c.newName}',
      );
    }
  }
  return null;
}
