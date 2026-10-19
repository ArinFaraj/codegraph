// What codegraph knows about Riverpod, in one place. The syntactic checks
// serve the parse-only verbs; [isProvider] is the resolved view of the same
// idea and is what resolved verbs use.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'kinds.dart';

/// `ref.<method>(provider)` calls and the role each one plays.
const providerRoles = {
  'watch': Role.refWatch,
  'read': Role.refRead,
  'listen': Role.refListen,
  'listenManual': Role.refListen,
  'invalidate': Role.refInvalidate,
  'refresh': Role.refRefresh,
  'exists': Role.refExists,
};

/// A top-level variable whose static type is a Riverpod provider.
bool isProvider(Element e) {
  if (e is! TopLevelVariableElement) return false;
  final type = e.type;
  if (type is! InterfaceType) return false;
  for (final t in [type, ...type.element.allSupertypes]) {
    final name = t.element.name ?? '';
    if (t.element.library.uri.toString().contains('riverpod') &&
        (name.endsWith('Provider') ||
            name.endsWith('ProviderBase') ||
            name.endsWith('ProviderListenable') ||
            name.endsWith('ProviderFamily'))) {
      return true;
    }
  }
  return false;
}

/// `NotifierProvider.autoDispose`, `FutureProvider.family` and friends, when
/// a top-level initializer constructs a provider. Syntax only.
String? providerKindOf(Expression? init) {
  if (init == null) return null;
  var head = init.toSource();
  final paren = head.indexOf('(');
  if (paren > 0) head = head.substring(0, paren);
  final lt = head.indexOf('<');
  final base = lt > 0 ? head.substring(0, lt) : head;
  final first = base.split('.').first;
  if (!RegExp(r'^[A-Z]\w*$').hasMatch(first) || !first.endsWith('Provider')) {
    return null;
  }
  return base.replaceAll(RegExp(r'\s+'), '');
}

bool isRiverpodAnnotated(NodeList<Annotation> metadata) =>
    metadata.any((a) => a.name.name == 'riverpod' || a.name.name == 'Riverpod');

/// The provider name riverpod_generator derives from an annotated function
/// or class: `fetchUser` and `FetchUser` both become `fetchUserProvider`.
String generatedProviderName(String sourceName) {
  final base = sourceName.startsWith('_')
      ? sourceName.substring(1)
      : sourceName;
  return '${base[0].toLowerCase()}${base.substring(1)}Provider';
}

/// `fooProvider` from `fooProvider`, `fooProvider(arg)`,
/// `fooProvider.notifier`, `fooProvider.select(...)`, `p.fooProvider`.
String? providerNameOf(Expression e) {
  var x = e;
  while (true) {
    switch (x) {
      case MethodInvocation(:final target, :final methodName):
        if (methodName.name.endsWith('Provider')) return methodName.name;
        if (target == null) return null;
        x = target;
      case FunctionExpressionInvocation(:final function):
        x = function;
      case PropertyAccess(:final target, :final propertyName):
        if (propertyName.name.endsWith('Provider')) return propertyName.name;
        if (target == null) return null;
        x = target;
      case PrefixedIdentifier(:final identifier, :final prefix):
        if (identifier.name.endsWith('Provider')) return identifier.name;
        return prefix.name.endsWith('Provider') ? prefix.name : null;
      case SimpleIdentifier(:final name):
        return name.endsWith('Provider') ? name : null;
      case ParenthesizedExpression(:final expression):
        x = expression;
      default:
        return null;
    }
  }
}
