// What codegraph knows about Riverpod, in one place: which elements are
// providers, and which `ref` calls read them.
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
