import 'dart:convert';

/// Exit codes shared by every verb.
abstract final class Exit {
  static const ok = 0;
  static const ambiguous = 2;
  static const refused = 3;
  static const usage = 64;
  static const cannotAnalyze = 66;
  static const failed = 1;
}

/// What a verb produces: text for people and agents, and the same facts as
/// JSON. Text is built from [lines]; the line limit applies only to rows.
class Result {
  Result(this.verb, {this.exit = Exit.ok});

  final String verb;
  int exit;
  final List<String> _header = [];
  final List<_Row> _rows = [];
  final List<String> _footer = [];
  final Map<String, Object?> json = {};

  void header(String line) => _header.add(line);

  void section(String title) => _rows.add(_Row(title, isTitle: true));

  void row(String line) => _rows.add(_Row(line));

  void footer(String line) => _footer.add(line);

  /// Marks the answer as partial. Exact answers carry no such line.
  void partial(String reason) {
    _footer.add('partial: $reason');
    json['partial'] = reason;
  }

  String render({required bool asJson, required int? limit}) {
    if (asJson) {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert({'verb': verb, 'exit': exit, ...json});
    }
    final out = <String>[..._header];
    var shown = 0;
    var hidden = 0;
    String? pendingTitle;
    for (final r in _rows) {
      if (r.isTitle) {
        pendingTitle = r.text;
        continue;
      }
      if (limit != null && shown >= limit) {
        hidden++;
        continue;
      }
      if (pendingTitle != null) {
        out.add(pendingTitle);
        pendingTitle = null;
      }
      out.add(r.text);
      shown++;
    }
    if (hidden > 0) out.add('$hidden more, rerun with --all');
    out.addAll(_footer);
    return out.join('\n');
  }
}

class _Row {
  _Row(this.text, {this.isTitle = false});
  final String text;
  final bool isTitle;
}

String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';
