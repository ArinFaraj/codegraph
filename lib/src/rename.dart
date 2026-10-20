// `rename` in two steps. [planRename] resolves the target, asks
// rename_rules.dart whether a rename is safe, and computes the edit set from
// the element model.
// [applyRename] installs a plan, re-analyzes what it touched, and restores
// every file if an error appeared.
import 'package:analyzer/dart/element/element.dart';

import 'analysis.dart';
import 'edits.dart';
import 'engine.dart';
import 'rename_rules.dart';
import 'result.dart';
import 'symbols.dart';
import 'verify.dart';
import 'workspace.dart';

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
  final candidate = RenameCandidate(
    engine,
    subject,
    target,
    await engine.overrideSet(subject),
    newName,
  );
  if (await refusalOf(candidate) case final refusal?) {
    return PlanRefused(refusal);
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

Future<Applied> applyRename(Engine engine, RenamePlan plan) =>
    applyChecked(engine, [
      for (final e in plan.edits)
        AtomicTextEdit(
          file: engine.workspace.absolute(e.path),
          offset: e.offset,
          length: plan.oldName.length,
          expected: plan.oldName,
          replacement: plan.newName,
        ),
    ], scope: plan.edits.map((e) => e.path).toSet());

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

/// Every element whose name a rename of [e] must change: the override set
/// with each member's getter, setter and field, the `this.x` and `super.x`
/// parameters that stand for a renamed field, and a named parameter's
/// counterparts across the override set.
Future<Bounded<Element>> _renameSet(RenameCandidate c) async {
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

class _Span implements Placed {
  _Span(this.path, this.offset);
  @override
  final String path;
  @override
  final int offset;
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
  for (final s in await analysis.references(elements)) {
    if (s.length > 0) add(s.path, s.offset);
  }
  return spans.values.toList()..sort(byPlace);
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
