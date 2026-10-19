import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

import 'edits.dart';
import 'engine.dart';
import 'result.dart';
import 'symbols.dart';
import 'workspace.dart';

/// Test seam: drop the edit at this index from the computed edit set, to
/// prove that post-apply analysis catches a missed reference and rolls back.
int? debugDropEditIndex;

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

const _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

class _Refusal implements Exception {
  _Refusal(this.kind, this.reason, [this.details = const []]);

  /// UNSAFE: renaming could break code we cannot see or change. UNSUPPORTED:
  /// codegraph does not compute this kind of rename yet.
  final String kind;
  final String reason;
  final List<String> details;
}

class _Span {
  _Span(this.path, this.offset, this.length);
  final String path;
  final int offset;
  final int length;
  String get key => '$path:$offset:$length';
}

Future<Result> rename(
  Engine engine,
  String query,
  String newName, {
  required bool apply,
}) async {
  final r = Result('rename')
    ..json['query'] = query
    ..json['newName'] = newName;
  if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(newName) ||
      _reserved.contains(newName)) {
    r.exit = Exit.usage;
    r.header('"$newName" is not a valid Dart identifier');
    return r;
  }
  final analysis = engine.analysis;
  final ws = analysis.workspace;
  final outline = engine.outlines();
  final found = await lookup(analysis, outline, query);
  if (found is NotFound) {
    r.exit = Exit.failed;
    r.header(found.message);
    r.footer('try: codegraph find $query');
    return r;
  }
  final targets = (found as Found).targets;
  if (targets.length > 1) {
    r.exit = Exit.ambiguous;
    r.header(
      '"$query" matches ${plural(targets.length, 'declaration')}; '
      'name one by path:line or Owner.member:',
    );
    for (final t in targets) {
      r.row('  ${t.kind} ${t.qualified}  ${t.location}');
    }
    return r;
  }

  final List<_Span> spans;
  final warnings = <String>[];
  final Element element;
  try {
    element = _normalize(targets.single.element);
    final oldName = element.name;
    if (oldName == null || oldName.isEmpty) {
      throw _Refusal('UNSUPPORTED', 'this declaration has no name to rename');
    }
    if (oldName == newName) {
      r.exit = Exit.usage;
      r.header(
        '${targetOf(analysis, element)!.qualified} is already named $newName',
      );
      return r;
    }
    spans = await _editSet(engine, element, newName, warnings);
  } on _Refusal catch (refusal) {
    r.exit = Exit.refused;
    r.header('${refusal.kind}: ${refusal.reason}');
    for (final d in refusal.details) {
      r.row('  $d');
    }
    r.json['refused'] = {
      'kind': refusal.kind,
      'reason': refusal.reason,
      'details': refusal.details,
    };
    if (refusal.kind == 'UNSUPPORTED') {
      r.footer(
        'codegraph cannot compute this rename yet. Renaming by hand is '
        'fine; run `dart analyze` afterwards.',
      );
    }
    return r;
  }

  final target = targetOf(analysis, element)!;
  final oldName = element.name!;
  final edits = <AtomicTextEdit>[];
  for (final s in spans) {
    edits.add(
      AtomicTextEdit(
        file: s.path,
        offset: s.offset,
        length: s.length,
        expected: oldName,
        replacement: newName,
      ),
    );
  }
  if (debugDropEditIndex case final i? when i < edits.length) {
    edits.removeAt(i);
  }
  final files = edits.map((e) => e.file).toSet().toList()..sort();
  r.header(
    '${apply ? 'renaming' : 'would rename'} ${target.kind} '
    '${target.qualified} -> $newName: ${plural(edits.length, 'edit')} in '
    '${plural(files.length, 'file')}${apply ? '' : ' (dry run; --apply to write)'}',
  );
  for (final e in edits) {
    final line = engine.sources.lineOf(e.file, e.offset);
    r.row(
      '  ${ws.relative(e.file)}:$line  ${engine.sources.lineText(e.file, line)}',
    );
  }
  for (final w in warnings) {
    r.footer('warning: $w');
  }
  r.json['target'] = {
    'name': target.qualified,
    'kind': target.kind,
    'path': target.path,
    'line': target.line,
  };
  r.json['edits'] = [
    for (final e in edits)
      {
        'path': ws.relative(e.file),
        'line': engine.sources.lineOf(e.file, e.offset),
        'offset': e.offset,
      },
  ];
  r.json['warnings'] = warnings;
  if (!apply) return r;

  final checkSet = <String>{...files};
  for (final f in files) {
    for (final importer in outline.importers(ws.relative(f))) {
      checkSet.add(ws.absolute(importer));
    }
  }
  final before = <String, Map<String, int>>{};
  for (final f in checkSet) {
    before[f] = _errorCounts(await analysis.errors(f));
  }

  final PreparedTextEdits prepared;
  try {
    prepared = prepareTextEdits(edits);
    applyPreparedTextEdits(prepared);
  } on AtomicEditException catch (e) {
    r.exit = Exit.failed;
    r.footer('not applied: ${e.message}');
    for (final d in [...e.details, ...e.recoveryPaths]) {
      r.footer('  $d');
    }
    return r;
  }
  await analysis.notifyChanged(files);

  final introduced = <String>[];
  for (final f in checkSet) {
    final now = await analysis.errors(f);
    final counts = _errorCounts(now);
    final was = before[f] ?? const {};
    for (final d in now) {
      final key = d.diagnosticCode.lowerCaseName;
      if ((counts[key] ?? 0) > (was[key] ?? 0)) {
        final line = engine.sources.lineOf(f, d.offset);
        introduced.add('${ws.relative(f)}:$line  ${d.message}');
      }
    }
  }
  if (introduced.isEmpty) {
    r.footer(
      'applied. Analysis of ${plural(checkSet.length, 'affected file')} '
      'shows no new errors.',
    );
    r.json['applied'] = true;
    r.json['checkedFiles'] = checkSet.length;
    return r;
  }

  try {
    restorePreparedTextEdits(prepared);
  } on AtomicEditException catch (e) {
    r.exit = Exit.failed;
    r.footer(
      'the rename introduced errors and restoring the files failed: ${e.message}',
    );
    for (final d in [...e.details, ...e.recoveryPaths]) {
      r.footer('  $d');
    }
    return r;
  }
  await analysis.notifyChanged(files);
  r.exit = Exit.refused;
  r.footer(
    'rolled back: the rename introduced ${plural(introduced.length, 'error')}, '
    'so every file was restored:',
  );
  for (final e in introduced.take(15)) {
    r.footer('  $e');
  }
  r.json['applied'] = false;
  r.json['rolledBack'] = introduced;
  return r;
}

Map<String, int> _errorCounts(List<Diagnostic> diagnostics) {
  final out = <String, int>{};
  for (final d in diagnostics) {
    final key = d.diagnosticCode.lowerCaseName;
    out[key] = (out[key] ?? 0) + 1;
  }
  return out;
}

/// Maps a parameter that stands for a field to the field, and a super
/// parameter to the parameter it forwards to.
Element _normalize(Element e) {
  var x = e;
  for (var i = 0; i < 20; i++) {
    if (x is SuperFormalParameterElement &&
        x.superConstructorParameter != null) {
      x = x.superConstructorParameter!.baseElement;
      continue;
    }
    if (x is FieldFormalParameterElement && x.field != null) {
      return x.field!.nonSynthetic;
    }
    break;
  }
  if (x is ConstructorElement &&
      (x.name == null || x.name == 'new' || x.name!.isEmpty)) {
    throw _Refusal(
      'UNSUPPORTED',
      'an unnamed constructor is named after its class; rename the class',
    );
  }
  if (x is LibraryElement) {
    throw _Refusal('UNSUPPORTED', 'renaming files is not supported yet');
  }
  return x.nonSynthetic;
}

Future<List<_Span>> _editSet(
  Engine engine,
  Element element,
  String newName,
  List<String> warnings,
) async {
  final analysis = engine.analysis;
  final ws = analysis.workspace;
  final oldName = element.name!;
  final target = targetOf(analysis, element)!;

  final declaringFile = ws.absolute(target.path);
  if (!analysis.isAnalyzed(declaringFile)) {
    throw _Refusal(
      'UNSAFE',
      '${target.qualified} is declared outside the analyzed '
          'workspace (${target.path}), so its other uses cannot be seen',
    );
  }
  if (element.isPrivate != newName.startsWith('_') &&
      element is! FormalParameterElement &&
      element is! LocalVariableElement) {
    throw _Refusal(
      'UNSAFE',
      'renaming ${target.qualified} to $newName changes its library privacy',
    );
  }

  _refuseCodegen(element);
  _refusePublished(ws, element, target);

  final members = await engine.hierarchyMembers(element);
  for (final m in members) {
    final f = m.firstFragment.libraryFragment;
    if (f == null || !analysis.isAnalyzed(f.source.fullName)) {
      final owner = m.enclosingElement?.displayName ?? '?';
      throw _Refusal(
        'UNSAFE',
        '${target.qualified} overrides or is overridden by $owner.$oldName, '
            'declared outside the workspace (${f?.source.uri ?? 'unknown'})',
      );
    }
    _refuseCodegen(m);
  }

  final owner = element.enclosingElement;
  final isInstanceMember =
      owner is InterfaceElement &&
      element is! ConstructorElement &&
      !(element is ExecutableElement && element.isStatic) &&
      !(element is FieldElement && element.isStatic);
  if (isInstanceMember || owner is ExtensionElement) {
    final dynamicUses = await analysis.unresolvedMemberReferences(oldName);
    if (dynamicUses.isNotEmpty) {
      throw _Refusal(
        'UNSAFE',
        '${plural(dynamicUses.length, 'call')} to .$oldName could not be '
            'resolved to a declaration (dynamic receivers or missing types); '
            'they may be uses of this member',
        [
          for (final s in dynamicUses.take(10))
            '${ws.relative(s.path)}:${engine.sources.lineOf(s.path, s.offset)}',
        ],
      );
    }
  }

  _refuseCollision(element, members, newName, target);

  final renamed = <Element>{};
  if (members.length > 1 || isInstanceMember) {
    for (final m in members) {
      renamed.addAll(engine.propertyFamily(m));
    }
  } else {
    renamed.addAll(engine.propertyFamily(element));
  }

  final fields = renamed.whereType<FieldElement>().toSet();
  if (fields.isNotEmpty) {
    final params = <FormalParameterElement>{};
    final classes = <InterfaceElement>{
      for (final f in fields)
        if (f.enclosingElement is InterfaceElement)
          f.enclosingElement as InterfaceElement,
    };
    for (final c in classes) {
      for (final ctor in c.constructors) {
        for (final p in ctor.formalParameters) {
          if (p is FieldFormalParameterElement &&
              fields.contains(p.field?.nonSynthetic)) {
            params.add(p);
          }
        }
      }
    }
    final subclasses = <InterfaceElement>{};
    for (final c in classes) {
      subclasses.addAll(await engine.subtypes(c));
    }
    var grew = true;
    while (grew) {
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
    renamed.addAll(params);
  }

  if (element is FormalParameterElement && element.isNamed) {
    final fn = element.enclosingElement;
    if (fn is ExecutableElement && fn.enclosingElement is InterfaceElement) {
      for (final m in await engine.hierarchyMembers(fn)) {
        if (m is ExecutableElement) {
          for (final p in m.formalParameters) {
            if (p.name == oldName) renamed.add(p);
          }
        }
      }
    }
  }

  final spans = <String, _Span>{};
  void add(_Span s) => spans.putIfAbsent(s.key, () => s);
  for (final e in renamed) {
    for (final fragment in e.fragments) {
      final offset = fragment.nameOffset;
      final lib = fragment.libraryFragment;
      if (offset == null || lib == null) continue;
      if (fragment.name != oldName) continue;
      add(_Span(ws.absolute(lib.source.fullName), offset, oldName.length));
    }
    for (final s in await analysis.references(e)) {
      add(_Span(s.path, s.offset, s.length));
    }
  }
  if (element is InterfaceElement) {
    for (final c in element.constructors) {
      for (final f in c.fragments) {
        final offset = f.typeNameOffset;
        if (offset == null) continue;
        add(
          _Span(
            ws.absolute(f.libraryFragment.source.fullName),
            offset,
            oldName.length,
          ),
        );
      }
    }
  }

  final out = <_Span>[];
  final mismatched = <String>[];
  for (final s in spans.values) {
    if (s.length == 0) continue;
    final text = engine.sources.text(s.path);
    if (s.offset + s.length > text.length ||
        text.substring(s.offset, s.offset + s.length) != oldName) {
      mismatched.add(
        '${ws.relative(s.path)}:${engine.sources.lineOf(s.path, s.offset)}',
      );
      continue;
    }
    if (!analysis.isAnalyzed(s.path)) {
      throw _Refusal(
        'UNSAFE',
        'a use sits in a file that is not analyzed: '
            '${ws.relative(s.path)}',
      );
    }
    out.add(s);
  }
  if (mismatched.isNotEmpty) {
    throw _Refusal(
      'UNSAFE',
      'the analyzer reported uses whose text is not "$oldName"; refusing an '
          'edit set that cannot be checked',
      mismatched.take(10).toList(),
    );
  }
  out.sort((a, b) {
    final c = a.path.compareTo(b.path);
    return c != 0 ? c : a.offset.compareTo(b.offset);
  });

  if (out.any((s) => isGeneratedFile(s.path))) {
    warnings.add(
      'edits generated files; they match what the generator would '
      'write, but rerun build_runner to confirm',
    );
  }
  if (element is FieldElement && element.isEnumConstant) {
    warnings.add(
      '$oldName is an enum value: .name, values.byName and '
      'serialized data spell it as a string, and stored or remote data may '
      'still say "$oldName"',
    );
  }
  final literal = _stringMentions(engine, oldName);
  if (literal.isNotEmpty) {
    warnings.add(
      'string literals mention "$oldName" and are not renamed: '
      '${literal.take(5).join(', ')}${literal.length > 5 ? ', ...' : ''}',
    );
  }
  return out;
}

void _refuseCodegen(Element e) {
  for (final candidate in [e, e.enclosingElement]) {
    if (candidate == null) continue;
    for (final a in candidate.metadata.annotations) {
      final ae = a.element;
      final name = ae is ConstructorElement
          ? ae.enclosingElement.name
          : ae?.name;
      if (name != null && _codegenAnnotations.contains(name)) {
        final on = candidate == e ? 'it' : candidate.displayName;
        throw _Refusal(
          'UNSAFE',
          '$on is annotated @$name: generated code and anything it '
              'serializes derive names from this declaration. Rename by hand, '
              'rerun build_runner, then check stored and wire formats',
        );
      }
    }
  }
}

void _refusePublished(Workspace ws, Element e, Target target) {
  if (e.isPrivate) return;
  final owner = e.enclosingElement;
  if (owner != null && owner is! LibraryElement && owner.isPrivate) return;
  if (e is LocalVariableElement || e is LocalFunctionElement) return;
  if (e is FormalParameterElement && !e.isNamed) return;
  final abs = ws.absolute(target.path);
  for (final root in ws.publishablePackageRoots()) {
    if (abs.startsWith('$root/lib/')) {
      throw _Refusal(
        'UNSAFE',
        '${target.qualified} is public API of ${ws.relative(root)}, whose '
            'pubspec does not say publish_to: none, so consumers outside this '
            'repository may use it',
      );
    }
  }
}

void _refuseCollision(
  Element element,
  List<Element> members,
  String newName,
  Target target,
) {
  final owners = <Element>{
    for (final m in members)
      if (m.enclosingElement case final o?) o,
    if (element.enclosingElement case final o?) o,
  };
  for (final o in owners) {
    if (o is InstanceElement && element is! FormalParameterElement) {
      final clash = [
        ...o.fields,
        ...o.getters,
        ...o.setters,
        ...o.methods,
      ].where((m) => m.name == newName);
      if (clash.isNotEmpty) {
        throw _Refusal(
          'UNSAFE',
          '${o.displayName} already has a member named $newName',
        );
      }
    }
    if (o is LibraryElement) {
      final clash = o.children.where((c) => c.name == newName);
      if (clash.isNotEmpty) {
        throw _Refusal(
          'UNSAFE',
          '${target.path} already declares a top-level $newName',
        );
      }
    }
  }
}

List<String> _stringMentions(Engine engine, String name) {
  if (name.length < 4) return const [];
  final ws = engine.workspace;
  final pattern = RegExp(
    '[\'"][^\'"\\n]*\\b${RegExp.escape(name)}\\b[^\'"\\n]*[\'"]',
  );
  final out = <String>[];
  for (final path in engine.analysis.files) {
    if (isGeneratedFile(path)) continue;
    final String text;
    try {
      text = File(path).readAsStringSync();
    } catch (_) {
      continue;
    }
    if (!text.contains(name)) continue;
    for (final m in pattern.allMatches(text)) {
      final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
      final lineText = text.split('\n')[line - 1].trimLeft();
      if (lineText.startsWith('import ') ||
          lineText.startsWith('export ') ||
          lineText.startsWith('part ') ||
          lineText.startsWith('//')) {
        continue;
      }
      out.add('${ws.relative(path)}:$line');
      if (out.length > 20) return out;
    }
  }
  return out;
}
