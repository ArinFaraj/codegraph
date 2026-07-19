import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

const refactorIndexPath = 'docs/maps/refactor_index.json';
const refactorIndexFormat = 5;

/// Machine-portable form of a library URI. Files under lib/ already resolve
/// to package: URIs, but anything outside it (test/, integration_test/,
/// tools/) comes out of the analyzer as file:///absolute/machine/path. Those
/// become root-relative (file:test/foo_test.dart) so the emitted artifacts
/// carry no machine paths and stay comparable across machines.
String portableLibraryUri(Uri uri) {
  if (uri.scheme != 'file') return uri.toString();
  final path = uri.path;
  for (final root in _rootPaths) {
    if (path.startsWith(root)) return 'file:${path.substring(root.length)}';
  }
  return uri.toString();
}

final List<String> _rootPaths = () {
  final cwd = Directory.current;
  // Both spellings: the analyzer may hand back resolved paths while the
  // process cwd goes through a symlink (or vice versa).
  return {
    cwd.uri.path,
    Directory(cwd.resolveSymbolicLinksSync()).uri.path,
  }.toList();
}();

const refactorSiteCall = 'call';
const refactorSiteReference = 'ref';
const _unresolvedSymbolPrefix = 'unresolved::';

class RefactorSite {
  const RefactorSite({
    required this.symbol,
    required this.file,
    required this.offset,
    required this.length,
    required this.line,
    required this.kind,
    this.containerSymbol,
  });

  factory RefactorSite.fromJson(Map<String, dynamic> json) => RefactorSite(
        symbol: json['symbol'] as String,
        file: json['file'] as String,
        offset: json['offset'] as int,
        length: json['length'] as int,
        line: json['line'] as int,
        kind: json['kind'] as String? ?? refactorSiteReference,
        containerSymbol: json['containerSymbol'] as String?,
      );

  final String symbol;
  final String file;
  final int offset;
  final int length;
  final int line;
  final String kind;
  final String? containerSymbol;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'file': file,
        'offset': offset,
        'length': length,
        'line': line,
        if (kind == refactorSiteCall) 'kind': kind,
        if (containerSymbol != null) 'containerSymbol': containerSymbol,
      };
}

class RefactorDeclaration extends RefactorSite {
  const RefactorDeclaration({
    required super.symbol,
    required super.file,
    required super.offset,
    required super.length,
    required super.line,
    super.kind = refactorSiteReference,
    required this.name,
    required this.owner,
    required this.library,
    required this.overrides,
    required this.scopeOffset,
    required this.scopeLength,
    required this.scopeStartLine,
    required this.scopeEndLine,
    required this.bodyOffset,
    required this.bodyLength,
    required this.bodyStartLine,
    required this.bodyEndLine,
    required this.declarationKind,
  });

  factory RefactorDeclaration.fromJson(Map<String, dynamic> json) =>
      RefactorDeclaration(
        symbol: json['symbol'] as String,
        file: json['file'] as String,
        offset: json['offset'] as int,
        length: json['length'] as int,
        line: json['line'] as int,
        kind: json['kind'] as String? ?? refactorSiteReference,
        name: json['name'] as String,
        owner: json['owner'] as String?,
        library: json['library'] as String,
        overrides: (json['overrides'] as List?)?.cast<String>() ?? const [],
        scopeOffset: json['scopeOffset'] as int,
        scopeLength: json['scopeLength'] as int,
        scopeStartLine: json['scopeStartLine'] as int,
        scopeEndLine: json['scopeEndLine'] as int,
        bodyOffset: json['bodyOffset'] as int,
        bodyLength: json['bodyLength'] as int,
        bodyStartLine: json['bodyStartLine'] as int,
        bodyEndLine: json['bodyEndLine'] as int,
        declarationKind: json['declarationKind'] as String,
      );

  final String name;
  final String? owner;
  final String library;
  final List<String> overrides;
  final int scopeOffset;
  final int scopeLength;
  final int scopeStartLine;
  final int scopeEndLine;
  final int bodyOffset;
  final int bodyLength;
  final int bodyStartLine;
  final int bodyEndLine;
  final String declarationKind;

  String get display => '${owner ?? '(top-level)'}.$name [$library]';

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'name': name,
        if (owner != null) 'owner': owner,
        'library': library,
        if (overrides.isNotEmpty) 'overrides': overrides,
        'scopeOffset': scopeOffset,
        'scopeLength': scopeLength,
        'scopeStartLine': scopeStartLine,
        'scopeEndLine': scopeEndLine,
        'bodyOffset': bodyOffset,
        'bodyLength': bodyLength,
        'bodyStartLine': bodyStartLine,
        'bodyEndLine': bodyEndLine,
        'declarationKind': declarationKind,
      };
}

class RefactorTarget {
  const RefactorTarget({
    required this.symbol,
    required this.name,
    required this.display,
    required this.library,
    required this.overrides,
  });

  factory RefactorTarget.fromJson(Map<String, dynamic> json) => RefactorTarget(
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        display: json['display'] as String,
        library: json['library'] as String,
        overrides: (json['overrides'] as List?)?.cast<String>() ?? const [],
      );

  final String symbol;
  final String name;
  final String display;
  final String library;
  final List<String> overrides;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'name': name,
        'display': display,
        'library': library,
        if (overrides.isNotEmpty) 'overrides': overrides,
      };
}

class RefactorIndex {
  RefactorIndex({
    required this.sourceDigest,
    required this.totalFiles,
    required this.resolvedFiles,
    required this.declarations,
    required this.references,
    required this.unresolvedNames,
    required this.nonExecutableNames,
    required this.targets,
  });

  factory RefactorIndex.fromJson(Map<String, dynamic> json) => RefactorIndex(
        sourceDigest: json['sourceDigest'] as int,
        totalFiles: json['totalFiles'] as int,
        resolvedFiles: json['resolvedFiles'] as int,
        declarations: (json['declarations'] as List)
            .cast<Map<String, dynamic>>()
            .map(RefactorDeclaration.fromJson)
            .toList(),
        references: (json['references'] as List)
            .cast<Map<String, dynamic>>()
            .map(RefactorSite.fromJson)
            .toList(),
        unresolvedNames:
            (json['unresolvedNames'] as List?)?.cast<String>() ?? const [],
        nonExecutableNames:
            (json['nonExecutableNames'] as List?)?.cast<String>() ?? const [],
        targets: (json['targets'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RefactorTarget.fromJson)
            .toList(),
      );

  final int sourceDigest;
  final int totalFiles;
  final int resolvedFiles;
  final List<RefactorDeclaration> declarations;
  final List<RefactorSite> references;
  final List<String> unresolvedNames;
  final List<String> nonExecutableNames;
  final List<RefactorTarget> targets;

  bool get complete => totalFiles == resolvedFiles;

  static RefactorIndex? load() {
    final file = File(refactorIndexPath);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['format'] != refactorIndexFormat) return null;
      return RefactorIndex.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static void remove() {
    final file = File(refactorIndexPath);
    if (file.existsSync()) file.deleteSync();
  }

  void write() {
    declarations.sort(_compareDeclaration);
    references.sort(_compareSite);
    unresolvedNames.sort();
    nonExecutableNames.sort();
    targets.sort((a, b) => a.symbol.compareTo(b.symbol));
    final file = File(refactorIndexPath)..parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'format': refactorIndexFormat,
            'sourceDigest': sourceDigest,
            'totalFiles': totalFiles,
            'resolvedFiles': resolvedFiles,
            'declarations': declarations.map((e) => e.toJson()).toList(),
            'references': references.map((e) => e.toJson()).toList(),
            if (unresolvedNames.isNotEmpty) 'unresolvedNames': unresolvedNames,
            if (nonExecutableNames.isNotEmpty)
              'nonExecutableNames': nonExecutableNames,
            'targets': targets.map((e) => e.toJson()).toList(),
          })}\n',
    );
  }
}

class RefactorIndexBuilder {
  final declarations = <RefactorDeclaration>[];
  final references = <RefactorSite>[];
  final unresolvedNames = <String>{};
  final nonExecutableNames = <String>{};
  final targets = <String, RefactorTarget>{};

  void addUnit(String file, CompilationUnit unit) {
    unit.accept(_IndexVisitor(
      file,
      unit.lineInfo,
      declarations,
      references,
      unresolvedNames,
      nonExecutableNames,
      targets,
    ));
  }

  RefactorIndex finish({
    required int sourceDigest,
    required int totalFiles,
    required int resolvedFiles,
  }) =>
      RefactorIndex(
        sourceDigest: sourceDigest,
        totalFiles: totalFiles,
        resolvedFiles: resolvedFiles,
        declarations: declarations,
        references: references,
        unresolvedNames: unresolvedNames.toList(),
        nonExecutableNames: nonExecutableNames.toList(),
        targets: targets.values.toList(),
      );
}

class _IndexVisitor extends RecursiveAstVisitor<void> {
  _IndexVisitor(
    this.file,
    this.lineInfo,
    this.declarations,
    this.references,
    this.unresolvedNames,
    this.nonExecutableNames,
    this.targets,
  );

  final String file;
  final LineInfo lineInfo;
  final List<RefactorDeclaration> declarations;
  final List<RefactorSite> references;
  final Set<String> unresolvedNames;
  final Set<String> nonExecutableNames;
  final Map<String, RefactorTarget> targets;
  final List<String> _containers = [];

  int _line(int offset) => lineInfo.getLocation(offset).lineNumber;

  void _recordTarget(ExecutableElement element) {
    final symbol = executableSymbol(element);
    final name = element.name;
    if (symbol == null || name == null || targets.containsKey(symbol)) return;
    final parents = _overriddenExecutables(element);
    targets[symbol] = RefactorTarget(
      symbol: symbol,
      name: name,
      display: executableElementDisplay(element),
      library: portableLibraryUri(element.library.uri),
      overrides: [
        for (final parent in parents)
          if (executableSymbol(parent) case final key?) key,
      ]..sort(),
    );
    for (final parent in parents) {
      _recordTarget(parent);
    }
  }

  String? _declaration(
    Element? element,
    int offset,
    int length,
    int scopeOffset,
    int scopeLength,
    int bodyOffset,
    int bodyLength,
    String declarationKind,
  ) {
    final symbol = executableSymbol(element);
    final name = element?.name;
    final libraryUri = element?.library?.uri;
    final library = libraryUri == null ? null : portableLibraryUri(libraryUri);
    if (symbol == null || name == null || library == null) return null;
    final executable = element! as ExecutableElement;
    _recordTarget(executable);
    final owner = _executableOwner(executable);
    final overrides = <String>[];
    for (final parent in _overriddenExecutables(executable)) {
      final key = executableSymbol(parent);
      if (key != null) overrides.add(key);
    }
    overrides.sort();
    declarations.add(
      RefactorDeclaration(
        symbol: symbol,
        file: file,
        offset: offset,
        length: length,
        line: _line(offset),
        kind: refactorSiteReference,
        name: name,
        owner: owner,
        library: library,
        overrides: overrides,
        scopeOffset: scopeOffset,
        scopeLength: scopeLength,
        scopeStartLine: _line(scopeOffset),
        scopeEndLine: _line(scopeOffset + scopeLength - 1),
        bodyOffset: bodyOffset,
        bodyLength: bodyLength,
        bodyStartLine: _line(bodyOffset),
        bodyEndLine: _line(bodyOffset + bodyLength - 1),
        declarationKind: declarationKind,
      ),
    );
    return symbol;
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final symbol = _declaration(
      node.declaredFragment?.element,
      node.name.offset,
      node.name.length,
      node.offset,
      node.length,
      node.body.offset,
      node.body.length,
      'method',
    );
    if (symbol == null) {
      super.visitMethodDeclaration(node);
      return;
    }
    _containers.add(symbol);
    try {
      super.visitMethodDeclaration(node);
    } finally {
      _containers.removeLast();
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final symbol = _declaration(
      node.declaredFragment?.element,
      node.name.offset,
      node.name.length,
      node.offset,
      node.length,
      node.functionExpression.body.offset,
      node.functionExpression.body.length,
      'function',
    );
    if (symbol == null) {
      super.visitFunctionDeclaration(node);
      return;
    }
    _containers.add(symbol);
    try {
      super.visitFunctionDeclaration(node);
    } finally {
      _containers.removeLast();
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!isRefactorReferenceUse(node)) {
      super.visitSimpleIdentifier(node);
      return;
    }
    final kind = refactorSiteKind(node);
    final symbol = executableSymbol(node.element);
    if (symbol != null) {
      _recordTarget(node.element! as ExecutableElement);
      references.add(
        RefactorSite(
          symbol: symbol,
          file: file,
          offset: node.offset,
          length: node.length,
          line: _line(node.offset),
          kind: kind,
          containerSymbol: _containers.lastOrNull,
        ),
      );
    } else if (node.element == null) {
      // Dynamic or unresolved uses cannot be attributed to a stable element.
      // Recording only the spelling lets an actuator refuse a target-specific
      // rename without making unrelated unresolved code poison the whole index.
      unresolvedNames.add(node.name);
      references.add(
        RefactorSite(
          symbol: '$_unresolvedSymbolPrefix${node.name}',
          file: file,
          offset: node.offset,
          length: node.length,
          line: _line(node.offset),
          kind: kind,
          containerSymbol: _containers.lastOrNull,
        ),
      );
    } else {
      nonExecutableNames.add(node.name);
    }
    super.visitSimpleIdentifier(node);
  }
}

String refactorSiteKind(SimpleIdentifier node) {
  final parent = node.parent;
  if (parent is MethodInvocation && identical(parent.methodName, node)) {
    return refactorSiteCall;
  }
  if (parent is FunctionExpressionInvocation &&
      identical(parent.function, node)) {
    return refactorSiteCall;
  }
  return refactorSiteReference;
}

bool isRefactorReferenceUse(SimpleIdentifier node) {
  final parent = node.parent;
  final isDeclaration =
      (parent is MethodDeclaration && identical(parent.name, node)) ||
          (parent is FunctionDeclaration && identical(parent.name, node)) ||
          (parent is VariableDeclaration && identical(parent.name, node)) ||
          parent is NamedType;
  return !isDeclaration;
}

String? executableSymbol(Element? element) {
  if (element is! ExecutableElement) return null;
  final name = element.name;
  final library = portableLibraryUri(element.library.uri);
  if (name == null) return null;
  final ownerName = _executableOwner(element);
  final owner = ownerName == null ? '' : '$ownerName.';
  return '$library::$owner$name';
}

String executableElementDisplay(ExecutableElement element) {
  final owner = _executableOwner(element);
  return owner == null ? (element.name ?? '?') : '$owner.${element.name}';
}

String? _executableOwner(ExecutableElement element) {
  final enclosing = element.enclosingElement;
  if (enclosing is LibraryElement) return null;
  final name = enclosing?.name;
  return name == null || name.isEmpty ? null : name;
}

List<ExecutableElement> _overriddenExecutables(ExecutableElement element) {
  final enclosing = element.enclosingElement;
  final name = element.name;
  if (enclosing is! InterfaceElement || name == null) return const [];
  return [
    for (final supertype in enclosing.thisType.allSupertypes)
      if (supertype.getMethod(name) case final method?) method,
  ];
}

String executableName(String symbol) {
  if (symbol.startsWith(_unresolvedSymbolPrefix)) {
    return symbol.substring(_unresolvedSymbolPrefix.length);
  }
  final separator = symbol.lastIndexOf('::');
  final qualified = separator == -1 ? symbol : symbol.substring(separator + 2);
  final dot = qualified.lastIndexOf('.');
  return dot == -1 ? qualified : qualified.substring(dot + 1);
}

String executableDisplay(String symbol) {
  if (symbol.startsWith(_unresolvedSymbolPrefix)) return '(unresolved)';
  final separator = symbol.lastIndexOf('::');
  return separator == -1 ? symbol : symbol.substring(separator + 2);
}

String executableLibrary(String symbol) {
  if (symbol.startsWith(_unresolvedSymbolPrefix)) return '(unresolved)';
  final separator = symbol.lastIndexOf('::');
  return separator == -1 ? '?' : symbol.substring(0, separator);
}

int _compareSite(RefactorSite a, RefactorSite b) {
  final bySymbol = a.symbol.compareTo(b.symbol);
  if (bySymbol != 0) return bySymbol;
  final byFile = a.file.compareTo(b.file);
  if (byFile != 0) return byFile;
  return a.offset.compareTo(b.offset);
}

int _compareDeclaration(RefactorDeclaration a, RefactorDeclaration b) =>
    _compareSite(a, b);
