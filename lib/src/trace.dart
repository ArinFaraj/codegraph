// `codegraph trace <file|-> [--json]` - resolve a Dart/Flutter stack trace to
// declarations in the graph, in one call.
//
// A trace hands you frame names and a URI per frame. Turning that into "which
// of these is my code, and where is it declared" is a grep per frame plus a
// file read per hit, and the answer is mostly framework frames the reader has
// to skip past. This maps every frame at once, marks the ones outside the
// workspace as external instead of dropping them, and names the innermost
// frame that is actually the host project's.
import 'dart:convert';
import 'dart:io';

import 'cli_util.dart';
import 'freshness.dart';
import 'model.dart';

/// One parsed stack frame. [uri] and [line] come from the trace; [path] and
/// [declLine] are what the graph could resolve, and are null when it could
/// not - never silently dropped, because a frame the graph cannot place is
/// exactly the frame a reader must not assume is irrelevant.
typedef Frame = ({
  int index,
  String symbol,
  String uri,
  int line,
  String? path,
  int? declLine,
});

/// `#12     Class.method.<anonymous closure> (package:app/x.dart:42:9)` and the
/// `file:///` form the VM prints for a non-package entrypoint. The column is
/// optional: web and some release traces omit it.
final _framePattern =
    RegExp(r'^#(\d+)\s+(.+?)\s+\((\S+?):(\d+)(?::(\d+))?\)\s*$');

/// The declared name a frame refers to: `new Foo.named` -> `Foo.named`, and
/// every closure suffix the VM appends (`.<anonymous closure>`, `.<fn>`)
/// collapses to the enclosing declaration, which is the thing that has a line
/// number in the graph.
String declaredName(String frameSymbol) {
  var s = frameSymbol.trim();
  if (s.startsWith('new ')) s = s.substring(4);
  final closure = s.indexOf('.<');
  if (closure >= 0) s = s.substring(0, closure);
  return s;
}

/// Workspace path for a frame [uri], or null when the frame is outside the
/// indexed tree (the SDK, a pub dependency, a generated shim).
///
/// Resolved against the graph rather than against pubspec `path:` deps: a
/// `package:x/a/b.dart` uri is `<something>/lib/a/b.dart`, and the graph
/// already knows every file it indexed. The host package lands on
/// `lib/a/b.dart`, a local package on `packages/x/lib/a/b.dart`, and matching
/// the package segment breaks the tie when both exist.
String? workspacePathFor(Graph graph, String uri) {
  if (uri.startsWith('dart:')) return null;
  String? tail;
  String? pkg;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    pkg = rest.substring(0, slash);
    tail = 'lib/${rest.substring(slash + 1)}';
  } else if (uri.startsWith('file://')) {
    final abs = Uri.parse(uri).toFilePath();
    final cwd = '${Directory.current.path}/';
    if (!abs.startsWith(cwd)) return null;
    tail = abs.substring(cwd.length);
  } else {
    tail = uri;
  }

  final candidates = graph.nodes
      .where((n) => n.isFile)
      .map((n) => n.id.replaceFirst('file:', ''))
      .where((p) => p == tail || p.endsWith('/$tail'))
      .toList()
    ..sort();
  if (candidates.isEmpty) return null;
  if (candidates.length == 1 || pkg == null) return candidates.first;
  return candidates.firstWhere(
    (p) => p.contains('/$pkg/lib/'),
    orElse: () => candidates.first,
  );
}

/// Declaration line for [name] within [path], searching top-level symbols
/// first and then class/mixin/extension members - the two places a frame
/// symbol can come from.
int? _declLineIn(Graph graph, String path, String name) {
  final node = graph.byId['file:$path'];
  if (node == null) return null;
  final last = name.split('.').last;
  for (final s in node.symbols) {
    if (s.name == name || s.name == last) return s.line;
  }
  for (final s in node.symbols) {
    for (final entry in s.memberIndex ?? s.members ?? const <String>[]) {
      if (isMemberCapTrailer(entry)) continue;
      final parsed = parseRenderedMember(entry);
      if (parsed != null && parsed.name == last) return parsed.line;
    }
  }
  return null;
}

/// Parses [text] into frames, resolving each against [graph]. Order is the
/// trace's own; `<asynchronous suspension>` markers carry no location and are
/// skipped rather than being invented into frames.
List<Frame> parseTrace(Graph graph, String text) {
  final frames = <Frame>[];
  for (final raw in text.split('\n')) {
    final m = _framePattern.firstMatch(raw.trimRight());
    if (m == null) continue;
    final symbol = m.group(2)!;
    final uri = m.group(3)!;
    final path = workspacePathFor(graph, uri);
    frames.add((
      index: int.parse(m.group(1)!),
      symbol: symbol,
      uri: uri,
      line: int.parse(m.group(4)!),
      path: path,
      declLine:
          path == null ? null : _declLineIn(graph, path, declaredName(symbol)),
    ));
  }
  return frames;
}

/// Drains stdin synchronously - the trace arrives piped
/// (`flutter run 2>&1 | codegraph trace -`), so there is nothing to wait for
/// asynchronously and the verb stays a one-shot like every other.
String _readStdin() {
  final chunks = <int>[];
  while (true) {
    final byte = stdin.readByteSync();
    if (byte < 0) break;
    chunks.add(byte);
  }
  return utf8.decode(chunks, allowMalformed: true);
}

/// `int run(List<String> args)` - `trace <file|-> [--json] [--budget N]`.
int run(List<String> args) {
  final positional = positionalArgs(args);
  final budget = intFlag(args, '--budget') ?? 80;
  final asJson = args.contains('--json');
  if (positional.length < 2) {
    stderr.writeln('usage: trace <file|-> [--json]');
    stderr.writeln('  - reads the trace from stdin');
    return 64;
  }
  final source = positional[1];

  final graph = loadFresh();
  if (graph == null) return 66;

  final String text;
  if (source == '-') {
    text = _readStdin();
  } else {
    final file = File(source);
    if (!file.existsSync()) {
      stderr.writeln('trace: no such file: $source');
      return 64;
    }
    text = file.readAsStringSync();
  }

  final frames = parseTrace(graph, text);
  if (frames.isEmpty) {
    if (asJson) {
      emitJson({...envelope('trace', source), 'frames': []});
      return 0;
    }
    emit([
      'no stack frames found in $source '
          '(${freshnessClause(graph.stats['files'] ?? 0)})',
      'expected VM frames shaped: #0  Symbol (package:app/file.dart:12:3)',
    ], budget);
    emitCaveats('trace');
    return 0;
  }

  final inWorkspace = frames.where((f) => f.path != null).toList();
  final first = inWorkspace.isEmpty ? null : inWorkspace.first;
  final churn = churnByPath();

  if (asJson) {
    emitJson({
      ...envelope('trace', source),
      'summary': {
        'frames': frames.length,
        'inWorkspace': inWorkspace.length,
        'firstWorkspaceFrame': first?.index,
      },
      'frames': frames
          .take(budget)
          .map((f) => {
                'index': f.index,
                'symbol': f.symbol,
                'uri': f.uri,
                'line': f.line,
                if (f.path != null) 'file': f.path,
                if (f.path != null) 'inDeg': graph.inDeg['file:${f.path}'] ?? 0,
                if (f.declLine != null) 'declLine': f.declLine,
                if (f.path != null && churn[f.path] != null)
                  'churn90d': churn[f.path],
                'external': f.path == null,
              })
          .toList(),
      if (frames.length > budget) 'truncated': frames.length - budget,
    });
    return 0;
  }

  final out = <String>[
    'trace: ${frames.length} frames, ${inWorkspace.length} in workspace'
        '${first == null ? '' : ', first workspace frame #${first.index}'}',
    if (churn.isNotEmpty)
      '(·N⇐ = files importing it; ~N = commits touching it in 90d)',
    '',
    for (final f in frames)
      if (f.path == null)
        '  #${f.index}  ${f.symbol}  external: ${f.uri}'
      else
        '  #${f.index}  ${f.symbol}  ${f.path}:${f.line}'
            '${f.declLine == null ? '' : ' (decl :${f.declLine})'}'
            '${inDegSuffix(graph.inDeg['file:${f.path}'] ?? 0)}'
            '${churnSuffix(churn, f.path!)}',
  ];
  emit(out, budget, hint: 'raise --budget N');
  emitCaveats('trace');
  return 0;
}
