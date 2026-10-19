// `why`: the import path from one file to another.
import 'dart:collection';

import 'kinds.dart';
import 'outline.dart';
import 'result.dart';
import 'symbols.dart';

/// One step of an import path: the importing file, the directive kind and
/// its line, and the file it reaches.
typedef WhyStep = ({String from, DirectiveKind kind, int line, String to});

class WhyAnswer extends Answer {
  WhyAnswer(this.from, this.to, this.steps, {required this.reversed});

  final String from;
  final String to;

  /// Null when the files are not connected.
  final List<WhyStep>? steps;
  final bool reversed;

  @override
  String get verb => 'why';

  @override
  void write(TextOut out) {
    final s = steps;
    if (s == null) {
      out.header('$from and $to are not connected by imports or exports');
      return;
    }
    out.header(
      '${s.first.from} reaches ${s.last.to} in ${plural(s.length, 'step')}'
      '${reversed ? ' (the reverse of what you asked)' : ''}',
    );
    out.row(s.first.from);
    for (final step in s) {
      out.row('  ${step.from}:${step.line} ${step.kind.label}s ${step.to}');
    }
  }

  @override
  Map<String, Object?> toJson() {
    final s = steps;
    return {
      'from': from,
      'to': to,
      'reversed': reversed,
      if (s != null) 'path': [s.first.from, for (final step in s) step.to],
    };
  }
}

Answer why(OutlineIndex idx, String fromArg, String toArg) {
  final files = idx.files.keys;
  final from = fileCandidates(idx.workspace, files, fromArg);
  if (from.length != 1) return FileChoiceAnswer('why', fromArg, from);
  final to = fileCandidates(idx.workspace, files, toArg);
  if (to.length != 1) return FileChoiceAnswer('why', toArg, to);

  List<WhyStep>? search(String a, String b) {
    final prev = <String, WhyStep>{};
    final queue = Queue<String>()..add(a);
    final seen = {a};
    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      if (cur == b) break;
      for (final (next, d) in idx.dependencies(cur)) {
        if (seen.add(next)) {
          prev[next] = (from: cur, kind: d.kind, line: d.line, to: next);
          queue.add(next);
        }
      }
    }
    if (!seen.contains(b)) return null;
    final path = <WhyStep>[];
    for (var cur = b; cur != a; cur = prev[cur]!.from) {
      path.add(prev[cur]!);
    }
    return path.reversed.toList();
  }

  final forward = search(from.single, to.single);
  if (forward != null) {
    return WhyAnswer(from.single, to.single, forward, reversed: false);
  }
  final back = search(to.single, from.single);
  return WhyAnswer(from.single, to.single, back, reversed: back != null);
}
