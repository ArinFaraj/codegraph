// `rename` in two steps. [planRename] resolves the target, checks whether a
// rename is safe, and computes the edit set from the element model.
// [applyRename] installs a plan, re-analyzes what it touched, and restores
// every file if an error appeared.
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

import 'edits.dart';
import 'engine.dart';
import 'rename_answers.dart';
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

class RenamePlan {
  RenamePlan(this.target, this.newName, this.edits, this.warnings);

  final Target target;
  final String newName;

  /// Workspace-relative edit spans. Mutable so a test can withhold one.
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

sealed class Applied {}

class AppliedClean extends Applied {
  AppliedClean(this.checkedFiles);
  final int checkedFiles;
}

class RolledBack extends Applied {
  RolledBack(this.errors);
  final List<String> errors;
}

class NotApplied extends Applied {
  NotApplied(this.message, this.details);
  final String message;
  final List<String> details;
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
  final r = await engine.resolve(query);
  if (failureOf('rename', query, r) case final failure?) {
    return PlanFailed(failure);
  }
  final element = _renamable((r as Resolved).target.element);
  if (element is Refusal) return PlanRefused(element);
  final e = element as Element;
  final target = targetOf(engine.analysis, e)!;
  if (e.name == newName) {
    return PlanFailed(
      MessageAnswer(
        'rename',
        '${target.qualified} is already named $newName',
        exit: Exit.usage,
      ),
    );
  }
  final members = await engine.overrideSet(e);
  final refusal = await _refusal(engine, e, target, members, newName);
  if (refusal != null) return PlanRefused(refusal);

  final elements = await _renameSet(engine, e, members);
  final spans = await _spans(engine, elements, e.name!);
  final mismatched = [
    for (final s in spans)
      if (!_holds(engine, s, e.name!))
        '${s.path}:${engine.sources.lineOf(s.path, s.offset)}',
  ];
  if (mismatched.isNotEmpty) {
    return PlanRefused(
      Refusal(
        RefusalKind.unsafe,
        'the analyzer reported uses whose text is not "${e.name}"; refusing '
        'an edit set that cannot be checked',
        mismatched.take(10).toList(),
      ),
    );
  }
  final edits = [
    for (final s in spans)
      RenameEdit(
        s.path,
        s.offset,
        engine.sources.lineOf(s.path, s.offset),
        engine.sources.lineText(
          s.path,
          engine.sources.lineOf(s.path, s.offset),
        ),
      ),
  ];
  return PlanReady(
    RenamePlan(target, newName, edits, _warnings(engine, e, spans)),
  );
}

Future<Applied> applyRename(Engine engine, RenamePlan plan) async {
  final analysis = engine.analysis;
  final ws = engine.workspace;
  final files = plan.edits.map((e) => e.path).toSet().toList()..sort();
  final checked = {
    ...files,
    for (final f in files) ...engine.outline.importers(f),
  };
  final before = {
    for (final f in checked) f: _errorCounts(await analysis.errors(f)),
  };

  final PreparedTextEdits prepared;
  try {
    prepared = prepareTextEdits([
      for (final e in plan.edits)
        AtomicTextEdit(
          file: ws.absolute(e.path),
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
  await _changed(engine, files);

  final introduced = <String>[];
  for (final f in checked) {
    final now = await analysis.errors(f);
    final counts = _errorCounts(now);
    final was = before[f]!;
    for (final d in now) {
      final key = d.diagnosticCode.lowerCaseName;
      if ((counts[key] ?? 0) > (was[key] ?? 0)) {
        introduced.add(
          '$f:${engine.sources.lineOf(f, d.offset)}  ${d.message}',
        );
      }
    }
  }
  if (introduced.isEmpty) return AppliedClean(checked.length);

  try {
    restorePreparedTextEdits(prepared);
  } on AtomicEditException catch (e) {
    return NotApplied(
      'the rename introduced errors and restoring the files failed: '
      '${e.message}',
      [...e.details, ...e.recoveryPaths, ...introduced],
    );
  }
  await _changed(engine, files);
  return RolledBack(introduced);
}

Future<void> _changed(Engine engine, List<String> files) async {
  await engine.analysis.notifyChanged(files);
  engine.filesChanged(files);
}

Map<String, int> _errorCounts(List<Diagnostic> diagnostics) {
  final out = <String, int>{};
  for (final d in diagnostics) {
    final key = d.diagnosticCode.lowerCaseName;
    out[key] = (out[key] ?? 0) + 1;
  }
  return out;
}

/// The element a rename of [e] actually renames: a `this.x` parameter
/// renames its field, a `super.x` parameter the parameter it forwards to.
/// Returns a [Refusal] for kinds that cannot be renamed.
Object _renamable(Element e) {
  var x = e;
  while (x is SuperFormalParameterElement &&
      x.superConstructorParameter != null) {
    x = x.superConstructorParameter!.baseElement;
  }
  if (x is FieldFormalParameterElement && x.field != null) x = x.field!;
  return switch (x) {
    ConstructorElement(name: null || '' || 'new') => Refusal(
      RefusalKind.unsupported,
      'an unnamed constructor is named after its class; rename the class',
    ),
    LibraryElement() => Refusal(
      RefusalKind.unsupported,
      'renaming files is not supported yet',
    ),
    Element(name: null || '') => Refusal(
      RefusalKind.unsupported,
      'this declaration has no name to rename',
    ),
    _ => x.nonSynthetic,
  };
}

Future<Refusal?> _refusal(
  Engine engine,
  Element e,
  Target target,
  List<Element> members,
  String newName,
) async {
  final analysis = engine.analysis;
  final oldName = e.name!;
  if (e.isPrivate != newName.startsWith('_') &&
      e is! FormalParameterElement &&
      e is! LocalVariableElement) {
    return Refusal(
      RefusalKind.unsafe,
      'renaming ${target.qualified} to $newName changes its library privacy',
    );
  }
  for (final m in members) {
    if (analysis.locate(m) == null) {
      return Refusal(
        RefusalKind.unsafe,
        '${target.qualified} overrides or is overridden by '
        '${m.enclosingElement?.displayName ?? '?'}.$oldName, declared outside '
        'the workspace (${analysis.sourceOf(m)})',
      );
    }
  }
  for (final m in {e, ...members}) {
    if (_codegenAnnotation(m) case (final on, final name)?) {
      return Refusal(
        RefusalKind.unsafe,
        '$on is annotated @$name: generated code and anything it serializes '
        'derive names from this declaration. Rename by hand, rerun '
        'build_runner, then check stored and wire formats',
      );
    }
  }
  if (_publishedRoot(engine.workspace, e, target) case final root?) {
    return Refusal(
      RefusalKind.unsafe,
      '${target.qualified} is public API of $root, whose pubspec does not say '
      'publish_to: none, so consumers outside this repository may use it',
    );
  }
  if (isInstanceMember(e) || e.enclosingElement is ExtensionElement) {
    final dynamicUses = await analysis.unresolvedMemberReferences(oldName);
    if (dynamicUses.isNotEmpty) {
      return Refusal(
        RefusalKind.unsafe,
        '${plural(dynamicUses.length, 'call')} to .$oldName could not be '
        'resolved to a declaration (dynamic receivers or missing types); '
        'they may be uses of this member',
        [
          for (final s in dynamicUses.take(10))
            '${s.path}:${engine.sources.lineOf(s.path, s.offset)}',
        ],
      );
    }
  }
  return _collision(e, members, newName, target);
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

Refusal? _collision(
  Element e,
  List<Element> members,
  String newName,
  Target target,
) {
  for (final o in {
    for (final m in {e, ...members}) ?m.enclosingElement,
  }) {
    if (o is InstanceElement && e is! FormalParameterElement) {
      final members = [...o.fields, ...o.getters, ...o.setters, ...o.methods];
      if (members.any((m) => m.name == newName)) {
        return Refusal(
          RefusalKind.unsafe,
          '${o.displayName} already has a member named $newName',
        );
      }
    }
    if (o is LibraryElement && o.children.any((c) => c.name == newName)) {
      return Refusal(
        RefusalKind.unsafe,
        '${target.path} already declares a top-level $newName',
      );
    }
  }
  return null;
}

/// Every element whose name a rename of [e] must change: the override set
/// with each member's getter, setter and field, the `this.x` and `super.x`
/// parameters that stand for a renamed field, and a named parameter's
/// counterparts across the override set.
Future<Set<Element>> _renameSet(
  Engine engine,
  Element e,
  List<Element> members,
) async {
  final out = {for (final m in members) ...engine.propertyFamily(m)};

  final fields = out.whereType<FieldElement>().toSet();
  final classes = {
    for (final f in fields)
      if (f.enclosingElement case final InterfaceElement c) c,
  };
  final params = <FormalParameterElement>{
    for (final c in classes)
      for (final ctor in c.constructors)
        for (final p in ctor.formalParameters)
          if (p is FieldFormalParameterElement &&
              fields.contains(p.field?.nonSynthetic))
            p,
  };
  final subclasses = {
    for (final c in classes) ...(await engine.subtypes(c)).types,
  };
  for (var grew = true; grew;) {
    grew = false;
    for (final c in subclasses) {
      for (final ctor in c.constructors) {
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
      for (final m in await engine.overrideSet(fn)) {
        if (m is ExecutableElement) {
          out.addAll(m.formalParameters.where((p) => p.name == e.name));
        }
      }
    }
  }
  return out;
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
      final path = analysis.workspace.relative(lib.source.fullName);
      if (analysis.isAnalyzed(path)) add(path, at);
    }
    for (final s in await analysis.references(e)) {
      if (s.length > 0) add(s.path, s.offset);
    }
    if (e is InterfaceElement) {
      for (final c in e.constructors) {
        for (final f in c.fragments) {
          if (f.typeNameOffset case final at?) {
            add(
              analysis.workspace.relative(f.libraryFragment.source.fullName),
              at,
            );
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
  for (final path in engine.analysis.files) {
    if (isGeneratedFile(path)) continue;
    final text = engine.sources.text(path);
    if (!text.contains(name)) continue;
    for (final m in pattern.allMatches(text)) {
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
