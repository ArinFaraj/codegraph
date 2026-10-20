import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'declarations.dart';
import 'kinds.dart';
import 'outline_model.dart';

FileOutline parseOutline(String path, String content) {
  final unit = parseString(content: content, throwIfDiagnostics: false).unit;
  final info = unit.lineInfo;
  int line(int offset) => info.getLocation(offset).lineNumber;

  final directives = <UriDirective?>[
    for (final d in unit.directives)
      switch (d) {
        ImportDirective() => UriDirective(
          DirectiveKind.import,
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        ExportDirective() => UriDirective(
          DirectiveKind.export,
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        PartDirective() => UriDirective(
          DirectiveKind.part,
          d.uri.stringValue ?? '',
          line(d.offset),
        ),
        PartOfDirective() => UriDirective(
          DirectiveKind.partOf,
          d.uri?.stringValue ?? d.libraryName?.toSource() ?? '',
          line(d.offset),
        ),
        _ => null,
      },
  ].nonNulls.toList();

  return FileOutline(
    path: path,
    lines: info.lineCount,
    decls: [
      for (final d in declarationsOf(unit))
        Decl(
          name: d.name,
          kind: d.kind,
          line: line(d.nameOffset),
          offset: d.offset,
          end: d.end,
          sig: d.sig,
          owner: d.owner,
          doc: d.doc,
        ),
    ],
    directives: directives,
  );
}
