// `rename` in two steps. [planRename] resolves the target, checks whether a
// rename is safe, and computes the edit set from the element model.
// [applyRename] installs a plan, re-analyzes what it touched, and restores
// every file if an error appeared.
import 'dart:async';

import 'package:analyzer/dart/element/element.dart';

import 'edits.dart';
import 'engine.dart';
import 'request.dart';
import 'result.dart';
import 'symbols.dart';
import 'verify.dart';
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

class RenamePlan {
  RenamePlan(this.target, this.newName, List<RenameEdit> edits, this.warnings)
    : edits = List.unmodifiable(edits);

  final Target target;
  final String newName;

  /// Workspace-relative edit spans.
  final List<RenameEdit> edits;
  final List<String> warnings;

  String get oldName => target.element.name!;
}

class RenameEdit {
  RenameEdit(this.path, this.offset, this.line, this.source);
  final String path;
  final int offset;
  final int line;

  /// The source line before the edit.
  final String source;
}

sealed class Planning {}

class PlanReady extends Planning {
  PlanReady(this.plan);
  final RenamePlan plan;
}

class PlanRefused extends Planning {
  PlanRefused(this.refusal);
  final Refusal refusal;
}

class PlanFailed extends Planning {
  PlanFailed(this.answer);
  final Answer answer;
}

Future<Answer> rename(
  Engine engine,
  String query,
  String newName, {
  required bool apply,
}) async {
  switch (await planRename(engine, query, newName)) {
    case PlanFailed(:final answer):
      return answer;
    case PlanRefused(:final refusal):
      return RefusalAnswer(refusal);
    case PlanReady(:final plan):
      return RenameAnswer(plan, apply ? await applyRename(engine, plan) : null);
  }
}

Future<Planning> planRename(Engine engine, String query, String newName) async {
  if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(newName) ||
      _reserved.contains(newName)) {
    return PlanFailed(
      MessageAnswer(
        'rename',
        '"$newName" is not a valid Dart identifier',
        exit: Exit.usage,
      ),
    );
  }
  final Element subject;
  switch (await engine.resolve(query)) {
    case Resolved(:final target):
      subject = _subject(target.element);
    case final Unresolved u:
      return PlanFailed(lookupFailure('rename', query, u));
  }
  if (_unsupported(subject) case final refusal?) return PlanRefused(refusal);
  final target = targetOf(engine.analysis, subject)!;
  if (subject.name == newName) {
    return PlanFailed(
      MessageAnswer(
        'rename',
        '${target.qualified} is already named $newName',
        exit: Exit.usage,
      ),
    );
  }
  final candidate = _Candidate(
    engine,
    subject,
    target,
    await engine.overrideSet(subject),
    newName,
  );
  for (final rule in _rules) {
    if (await rule(candidate) case final refusal?) return PlanRefused(refusal);
  }

  final elements = await _renameSet(candidate);
  if (elements.truncated) {
    return PlanRefused(
      Refusal(
        RefusalKind.unsafe,
        'a class behind ${target.qualified} has more than '
        '${Engine.subtypeCap} subtypes, so the edit set may be incomplete',
      ),
    );
  }
  final oldName = subject.name!;
  final spans = await _spans(engine, elements.items.toSet(), oldName);
  final edits = <RenameEdit>[];
  final mismatched = <String>[];
  for (final s in spans) {
    final line = engine.sources.lineOf(s.path, s.offset);
    if (_holds(engine, s, oldName)) {
      edits.add(
        RenameEdit(
          s.path,
          s.offset,
          line,
          engine.sources.lineText(s.path, line),
        ),
      );
    } else {
      mismatched.add('${s.path}:$line');
    }
  }
  if (mismatched.isNotEmpty) {
    return PlanRefused(
      Refusal(
        RefusalKind.unsafe,
        'the analyzer reported uses whose text is not "$oldName"; refusing '
        'an edit set that cannot be checked',
        mismatched.take(10).toList(),
      ),
    );
  }
  return PlanReady(
    RenamePlan(target, newName, edits, _warnings(engine, subject, spans)),
  );
}

Future<Applied> applyRename(Engine engine, RenamePlan plan) async {
  final files = plan.edits.map((e) => e.path).toSet().toList()..sort();
  final baseline = await ErrorBaseline.take(engine, files);

  final PreparedTextEdits prepared;
  try {
    prepared = prepareTextEdits([
      for (final e in plan.edits)
        AtomicTextEdit(
          file: engine.workspace.absolute(e.path),
          offset: e.offset,
          length: plan.oldName.length,
          expected: plan.oldName,
          replacement: plan.newName,
        ),
    ]);
    applyPreparedTextEdits(prepared);
  } on AtomicEditException catch (e) {
    return NotApplied(e.message, [...e.details, ...e.recoveryPaths]);
  }
  await filesWritten(engine, files);

  final introduced = await baseline.introduced(engine);
  if (introduced.isEmpty) return AppliedClean(baseline.fileCount);
  try {
    restorePreparedTextEdits(prepared);
  } on AtomicEditException catch (e) {
    return NotApplied(
      'the rename introduced errors and restoring the files failed: '
      '${e.message}',
      [...e.details, ...e.recoveryPaths, ...introduced],
    );
  }
  await filesWritten(engine, files);
  return RolledBack(introduced);
}

/// The element a rename of [e] actually renames: a `this.x` parameter
/// renames its field, a `super.x` parameter the parameter it forwards to.
Element _subject(Element e) {
  var x = e;
  while (x is SuperFormalParameterElement &&
      x.superConstructorParameter != null) {
    x = x.superConstructorParameter!.baseElement;
  }
  if (x is FieldFormalParameterElement && x.field != null) x = x.field!;
  return x.nonSynthetic;
}

Refusal? _unsupported(Element e) => switch (e) {
  ConstructorElement(name: null || '' || 'new') => Refusal(
    RefusalKind.unsupported,
    'an unnamed constructor is named after its class; rename the class',
  ),
  LibraryElement() => Refusal(
    RefusalKind.unsupported,
    'to move a file, run: codegraph rename <a.dart> <b.dart>',
  ),
  Element(name: null || '') => Refusal(
    RefusalKind.unsupported,
    'this declaration has no name to rename',
  ),
  _ => null,
};

/// What every refusal rule looks at.
class _Candidate {
  _Candidate(
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

typedef _Rule = FutureOr<Refusal?> Function(_Candidate c);

/// Each rule names one way a rename could break code codegraph cannot see
/// or change. The first that applies refuses the rename.
const List<_Rule> _rules = [
  _privacyChange,
  _incompleteHierarchy,
  _overridesOutside,
  _codeGeneration,
  _publishedApi,
  _dynamicUses,
  _collision,
];

Refusal? _privacyChange(_Candidate c) {
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

Refusal? _incompleteHierarchy(_Candidate c) => c.members.truncated
    ? Refusal(
        RefusalKind.unsafe,
        'the class hierarchy around ${c.target.qualified} has more than '
        '${Engine.subtypeCap} subtypes, so its override set may be incomplete',
      )
    : null;

Refusal? _overridesOutside(_Candidate c) {
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

Refusal? _codeGeneration(_Candidate c) {
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

Refusal? _publishedApi(_Candidate c) {
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

Future<Refusal?> _dynamicUses(_Candidate c) async {
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

Refusal? _collision(_Candidate c) {
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

/// Every element whose name a rename of [e] must change: the override set
/// with each member's getter, setter and field, the `this.x` and `super.x`
/// parameters that stand for a renamed field, and a named parameter's
/// counterparts across the override set.
Future<Bounded<Element>> _renameSet(_Candidate c) async {
  final engine = c.engine;
  final e = c.element;
  final out = {for (final m in c.members.items) ...engine.propertyFamily(m)};

  final fields = out.whereType<FieldElement>().toSet();
  final classes = {
    for (final f in fields)
      if (f.enclosingElement case final InterfaceElement owner) owner,
  };
  final params = <FormalParameterElement>{
    for (final owner in classes)
      for (final ctor in owner.constructors)
        for (final p in ctor.formalParameters)
          if (p is FieldFormalParameterElement &&
              fields.contains(p.field?.nonSynthetic))
            p,
  };
  var truncated = false;
  final subclasses = <InterfaceElement>{};
  for (final owner in classes) {
    final subs = await engine.subtypes(owner);
    truncated |= subs.truncated;
    subclasses.addAll(subs.items);
  }
  for (var grew = true; grew;) {
    grew = false;
    for (final sub in subclasses) {
      for (final ctor in sub.constructors) {
        for (final p in ctor.formalParameters) {
          if (p is SuperFormalParameterElement &&
              params.contains(p.superConstructorParameter?.baseElement) &&
              params.add(p)) {
            grew = true;
          }
        }
      }
    }
  }
  out.addAll(params);

  if (e is FormalParameterElement && e.isNamed) {
    final fn = e.enclosingElement;
    if (fn is ExecutableElement && isInstanceMember(fn)) {
      final set = await engine.overrideSet(fn);
      truncated |= set.truncated;
      for (final m in set.items) {
        if (m is ExecutableElement) {
          out.addAll(m.formalParameters.where((p) => p.name == e.name));
        }
      }
    }
  }
  return Bounded(out.toList(), truncated: truncated);
}

class _Span {
  _Span(this.path, this.offset);
  final String path;
  final int offset;
  String get key => '$path:$offset';
}

/// The declaration names and use sites of [elements], plus the type name of
/// each constructor declaration when a class is renamed.
Future<List<_Span>> _spans(
  Engine engine,
  Set<Element> elements,
  String oldName,
) async {
  final analysis = engine.analysis;
  final spans = <String, _Span>{};
  void add(String path, int offset) =>
      spans.putIfAbsent('$path:$offset', () => _Span(path, offset));
  for (final e in elements) {
    for (final f in e.fragments) {
      final at = f.nameOffset;
      final lib = f.libraryFragment;
      if (at == null || lib == null || f.name != oldName) continue;
      final path = analysis.workspace.relativeOrNull(lib.source.fullName);
      if (path != null && analysis.isAnalyzed(path)) add(path, at);
    }
    for (final s in await analysis.references(e)) {
      if (s.length > 0) add(s.path, s.offset);
    }
    if (e is InterfaceElement) {
      for (final c in e.constructors) {
        for (final f in c.fragments) {
          if (f.typeNameOffset case final at?) {
            final path = analysis.workspace.relativeOrNull(
              f.libraryFragment.source.fullName,
            );
            if (path != null && analysis.isAnalyzed(path)) add(path, at);
          }
        }
      }
    }
  }
  return spans.values.toList()..sort((a, b) {
    final c = a.path.compareTo(b.path);
    return c != 0 ? c : a.offset.compareTo(b.offset);
  });
}

bool _holds(Engine engine, _Span s, String oldName) {
  final text = engine.sources.text(s.path);
  return s.offset + oldName.length <= text.length &&
      text.substring(s.offset, s.offset + oldName.length) == oldName;
}

List<String> _warnings(Engine engine, Element e, List<_Span> spans) {
  final oldName = e.name!;
  final literals = _stringMentions(engine, oldName);
  return [
    if (spans.any((s) => isGeneratedFile(s.path)))
      'edits generated files; they match what the generator would write, '
          'but rerun build_runner to confirm',
    if (e is FieldElement && e.isEnumConstant)
      '$oldName is an enum value: .name, values.byName and serialized data '
          'spell it as a string, and stored or remote data may still say '
          '"$oldName"',
    if (literals.isNotEmpty)
      'string literals mention "$oldName" and are not renamed: '
          '${literals.take(5).join(', ')}${literals.length > 5 ? ', ...' : ''}',
  ];
}

/// String literals spelling [name] as a word, outside directives and
/// comments, as `path:line`.
List<String> _stringMentions(Engine engine, String name) {
  if (name.length < 4) return const [];
  final pattern = RegExp(
    '[\'"][^\'"\\n]*\\b${RegExp.escape(name)}\\b[^\'"\\n]*[\'"]',
  );
  final out = <String>[];
  final candidates = [
    for (final path in engine.analysis.files)
      if (!isGeneratedFile(path) && engine.sources.text(path).contains(name))
        path,
  ]..sort();
  for (final path in candidates) {
    for (final m in pattern.allMatches(engine.sources.text(path))) {
      final line = engine.sources.lineOf(path, m.start);
      final source = engine.sources.lineText(path, line);
      if (RegExp(r'^(import|export|part)\b|^//').hasMatch(source)) continue;
      out.add('$path:$line');
      if (out.length > 20) return out;
    }
  }
  return out;
}

const _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

class RenameRequest extends WorkerRequest {
  RenameRequest(
    this.query,
    this.newName, {
    required this.apply,
    required super.json,
    required super.limit,
  });

  RenameRequest.fromJson(Map<String, dynamic> j)
    : this(
        j['query'] as String,
        j['newName'] as String,
        apply: j['apply'] as bool,
        json: j['json'] as bool,
        limit: j['limit'] as int?,
      );

  final String query;
  final String newName;
  final bool apply;

  @override
  String get verb => 'rename';

  @override
  Map<String, Object?> get fields => {
    'query': query,
    'newName': newName,
    'apply': apply,
  };

  @override
  Future<Answer> run(Engine engine) =>
      rename(engine, query, newName, apply: apply);
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

class RenameAnswer extends Answer {
  RenameAnswer(this.plan, this.applied);

  final RenamePlan plan;

  /// Null for a dry run.
  final Applied? applied;

  @override
  String get verb => 'rename';

  @override
  int get exit => appliedExit(applied);

  @override
  void write(TextOut out) {
    final files = plan.edits.map((e) => e.path).toSet();
    final t = plan.target;
    out.header(
      '${applied == null ? 'would rename' : 'renaming'} ${t.kind} '
      '${t.qualified} -> ${plan.newName}: ${plural(plan.edits.length, 'edit')} '
      'in ${plural(files.length, 'file')}'
      '${applied == null ? ' (dry run; --apply to write)' : ''}',
    );
    for (final e in plan.edits) {
      out.row('  ${e.path}:${e.line}  ${e.source}');
    }
    for (final w in plan.warnings) {
      out.footer('warning: $w');
    }
    writeApplied(
      out,
      applied,
      done: 'applied',
      rolledBack: (errors) =>
          'rolled back: the rename introduced '
          '${plural(errors.length, 'error')}, so every file was restored:',
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'target': plan.target.toJson(),
    'newName': plan.newName,
    'edits': [
      for (final e in plan.edits)
        {'path': e.path, 'line': e.line, 'offset': e.offset},
    ],
    'warnings': plan.warnings,
    if (applied case final a?) 'applied': appliedJson(a),
  };
}
