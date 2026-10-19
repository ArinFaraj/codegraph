// Differential check before a release: codegraph's references against the
// Dart language server's, on sampled declarations of a real workspace.
//
//   dart run tool/lsp_diff.dart <workspace> [--sample 200] [--settle 180]
//
// The language server answers early and incompletely while it is still
// analyzing, so this waits until its answers stop changing. Its reference
// search reports `show`/`hide` combinators for some kinds and not for
// getters, so codegraph may list combinators the server does not.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:codegraph/src/analysis.dart';
import 'package:codegraph/src/engine.dart';
import 'package:codegraph/src/outline.dart';
import 'package:codegraph/src/workspace.dart';

Future<void> main(List<String> args) async {
  final ws = Workspace.find(args.first)!;
  int flag(String name, int fallback) {
    final i = args.indexOf(name);
    return i >= 0 ? int.parse(args[i + 1]) : fallback;
  }

  final sample = flag('--sample', 200);
  final settle = flag('--settle', 180);

  final outline = OutlineIndex.load(ws);
  final candidates = <(String, Decl)>[
    for (final f in outline.files.values)
      if (f.path.startsWith('lib/') && !isGeneratedFile(f.path))
        for (final d in f.decls)
          if (!d.isMember &&
              d.kind != 'provider' &&
              !d.name.startsWith('_') &&
              !d.name.startsWith('<'))
            (f.path, d),
  ]..shuffle(Random(4));
  final picked = candidates.take(sample).toList();

  final lsp = await _Lsp.start(ws.root);
  final probe = picked.first;
  stdout.writeln(
    'waiting for the language server to settle (up to ${settle}s)',
  );
  var last = -1;
  var stableSince = DateTime.now();
  final deadline = DateTime.now().add(Duration(seconds: settle));
  while (DateTime.now().isBefore(deadline)) {
    final n = (await lsp.references(ws, probe.$1, probe.$2)).length;
    if (n != last) {
      last = n;
      stableSince = DateTime.now();
    } else if (DateTime.now().difference(stableSince) >
        const Duration(seconds: 30)) {
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }

  final analysis = await Analysis.open(ws);
  await analysis.warmUp();
  final engine = Engine(analysis);
  var agree = 0;
  final disagreements = <String>[];
  for (final (path, d) in picked) {
    final theirs = (await lsp.references(ws, path, d)).toSet();
    final r = await engine.refs('$path:${d.line}');
    final uses = [
      for (final u in (r.toJson()['uses'] as List?) ?? const [])
        u as Map<String, dynamic>,
    ];
    final ours = {for (final u in uses) '${u['path']}:${u['line']}'};
    final combinators = {
      for (final u in uses)
        if (u['role'] == 'import') '${u['path']}:${u['line']}',
    };
    if (theirs.difference(ours).isEmpty &&
        ours.difference(theirs).difference(combinators).isEmpty) {
      agree++;
    } else {
      disagreements.add(
        '${d.name} ($path:${d.line}): '
        'only lsp ${theirs.difference(ours).take(3).toList()}, '
        'only codegraph ${ours.difference(theirs).take(3).toList()}',
      );
    }
  }
  stdout.writeln('agree on $agree of ${picked.length} declarations');
  disagreements.forEach(stdout.writeln);
  await analysis.dispose();
  lsp.kill();
  exit(disagreements.isEmpty ? 0 : 1);
}

class _Lsp {
  _Lsp(this._process) {
    _process.stdout.listen(_onData);
  }

  final Process _process;
  final _buffer = <int>[];
  final _pending = <int, Completer<Object?>>{};
  var _id = 0;

  static Future<_Lsp> start(String root) async {
    final p = await Process.start('dart', [
      'language-server',
      '--protocol=lsp',
      '--client-id=codegraph-diff',
    ], workingDirectory: root);
    p.stderr.drain<void>();
    final lsp = _Lsp(p);
    final uri = Uri.directory(root).toString();
    await lsp._request('initialize', {
      'processId': pid,
      'rootUri': uri,
      'workspaceFolders': [
        {'uri': uri, 'name': 'root'},
      ],
      'capabilities': <String, Object>{},
    });
    lsp._send({
      'jsonrpc': '2.0',
      'method': 'initialized',
      'params': <String, Object>{},
    });
    return lsp;
  }

  Future<List<String>> references(Workspace ws, String path, Decl d) async {
    final text = File('${ws.root}/$path').readAsLinesSync();
    final line = d.line - 1;
    final col =
        RegExp(
          '\\b${RegExp.escape(d.name)}\\b',
        ).firstMatch(text[line])?.start ??
        -1;
    if (col < 0) return const [];
    final result = await _request('textDocument/references', {
      'textDocument': {'uri': Uri.file('${ws.root}/$path').toString()},
      'position': {'line': line, 'character': col},
      'context': {'includeDeclaration': false},
    });
    return [
      for (final r in (result as List?) ?? const [])
        '${ws.relative(Uri.parse((r as Map)['uri'] as String).toFilePath())}:'
            '${(((r['range'] as Map)['start'] as Map)['line'] as int) + 1}',
    ];
  }

  Future<Object?> _request(String method, Object params) {
    final id = ++_id;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    _process.stdin.add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'));
    _process.stdin.add(body);
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    while (true) {
      final text = latin1.decode(_buffer, allowInvalid: true);
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      final m = RegExp(
        r'Content-Length: (\d+)',
      ).firstMatch(text.substring(0, headerEnd));
      if (m == null) return;
      final length = int.parse(m.group(1)!);
      final start = headerEnd + 4;
      if (_buffer.length < start + length) return;
      final message = jsonDecode(
        utf8.decode(_buffer.sublist(start, start + length)),
      );
      _buffer.removeRange(0, start + length);
      if (message is Map &&
          message['id'] is int &&
          !message.containsKey('method')) {
        _pending.remove(message['id'])?.complete(message['result']);
      }
    }
  }

  void kill() => _process.kill();
}
