import 'dart:convert';

import 'symbols.dart';

/// Exit codes shared by every verb.
abstract final class Exit {
  static const ok = 0;
  static const failed = 1;
  static const ambiguous = 2;
  static const refused = 3;
  static const usage = 64;
  static const cannotAnalyze = 66;
}

/// What a verb answers. Text and JSON are both written from the same fields,
/// so the two cannot say different things.
abstract class Answer {
  String get verb;
  int get exit => Exit.ok;

  void write(TextOut out);
  Map<String, Object?> toJson();

  String render({required bool asJson, required int? limit}) {
    if (asJson) {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert({'verb': verb, 'exit': exit, ...toJson()});
    }
    final out = TextOut();
    write(out);
    return out.build(limit);
  }
}

/// Text output: header lines, titled sections of rows (the rows are what a
/// line limit cuts), and footer lines.
class TextOut {
  final List<String> _header = [];
  final List<(String, bool)> _rows = [];
  final List<String> _footer = [];

  void header(String line) => _header.add(line);
  void section(String title) => _rows.add((title, true));
  void row(String line) => _rows.add((line, false));
  void footer(String line) => _footer.add(line);
  void partial(String reason) => _footer.add('partial: $reason');

  String build(int? limit) {
    final out = [..._header];
    var shown = 0;
    var hidden = 0;
    String? title;
    for (final (text, isTitle) in _rows) {
      if (isTitle) {
        title = text;
      } else if (limit != null && shown >= limit) {
        hidden++;
      } else {
        if (title != null) out.add(title);
        title = null;
        out.add(text);
        shown++;
      }
    }
    if (hidden > 0) out.add('$hidden more, rerun with --all');
    return [...out, ..._footer].join('\n');
  }
}

/// A one-line answer: not found, a usage problem, a failure.
class MessageAnswer extends Answer {
  MessageAnswer(this.verb, this.message, {this.hint, this.exit = Exit.failed});

  @override
  final String verb;
  final String message;
  final String? hint;

  @override
  final int exit;

  @override
  void write(TextOut out) {
    out.header(message);
    if (hint != null) out.footer(hint!);
  }

  @override
  Map<String, Object?> toJson() => {'error': message};
}

class AmbiguousAnswer extends Answer {
  AmbiguousAnswer(this.verb, this.query, this.targets);

  @override
  final String verb;
  final String query;
  final List<Target> targets;

  @override
  int get exit => Exit.ambiguous;

  @override
  void write(TextOut out) {
    out.header(
      '"$query" matches ${plural(targets.length, 'declaration')}; '
      'name one by path:line or Owner.member:',
    );
    for (final t in targets) {
      out.row('  ${t.kind} ${t.qualified}  ${t.location}');
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'candidates': [for (final t in targets) t.toJson()],
  };
}

/// One answer per declaration, for a name that matches a few of them.
class EachAnswer extends Answer {
  EachAnswer(this.verb, this.query, this.answers);

  @override
  final String verb;
  final String query;
  final List<Answer> answers;

  @override
  int get exit =>
      answers.every((a) => a.exit == Exit.ok) ? Exit.ok : answers.first.exit;

  @override
  void write(TextOut out) => out.header(
    '"$query" names ${plural(answers.length, 'declaration')}; each is '
    'answered below. Name one by path:line or Owner.member to see only it.',
  );

  @override
  String render({required bool asJson, required int? limit}) {
    if (asJson) return super.render(asJson: true, limit: limit);
    final head = TextOut();
    write(head);
    return [
      head.build(null),
      for (final a in answers) a.render(asJson: false, limit: limit),
    ].join('\n\n');
  }

  @override
  Map<String, Object?> toJson() => {
    'query': query,
    'answers': [for (final a in answers) a.toJson()],
  };
}

/// A file argument that matched no file, or several.
class FileChoiceAnswer extends Answer {
  FileChoiceAnswer(this.verb, this.arg, this.candidates);

  @override
  final String verb;
  final String arg;
  final List<String> candidates;

  @override
  int get exit => candidates.isEmpty ? Exit.failed : Exit.ambiguous;

  @override
  void write(TextOut out) {
    out.header(
      candidates.isEmpty
          ? 'no analyzed file matches "$arg"'
          : '"$arg" matches ${plural(candidates.length, 'file')}:',
    );
    for (final p in candidates) {
      out.row('  $p');
    }
  }

  @override
  Map<String, Object?> toJson() => {'candidates': candidates};
}

/// Why a lookup did not find exactly one declaration.
Answer lookupFailure(String verb, String query, Unresolved u) => switch (u) {
  Ambiguous(:final targets) => AmbiguousAnswer(verb, query, targets),
  Missing(:final message) => MessageAnswer(
    verb,
    message,
    hint: 'try: codegraph find $query',
  ),
};

String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';
