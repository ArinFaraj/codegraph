// Shared CLI plumbing for the query-side verbs (query.dart, brief.dart,
// diff.dart, impact.dart). One definition each of: the line-budgeted output
// contract, the shared-remaining-count JSON budget, the capped-join list
// renderer, and the in-degree "reader count" suffix — every verb printed
// these identically; this is the single copy.
import 'dart:io';

int? intFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return int.tryParse(args[i + 1]);
  return null;
}

void emit(List<String> lines, int budget, {String? hint}) {
  for (final l in lines.take(budget)) {
    stdout.writeln(l);
  }
  if (lines.length > budget) {
    stdout.writeln(
      '… ${lines.length - budget} more (raise --budget to see all)',
    );
    if (hint != null) stdout.writeln('  ($hint)');
  }
}

/// Joins [items] capped at 10 + a `", … N more"` trailer — every file/provider
/// list line in a brief/diff card must stay short even when the underlying
/// list is 100+ items.
String joinCapped(List<String> items) {
  final shown = items.take(10).join(', ');
  final more = items.length > 10 ? ', … ${items.length - 10} more' : '';
  return '$shown$more';
}

/// `n > 0 ? ' ·N⇐' : ''` — the in-degree "reader count" suffix appended to a
/// file/provider line across brief/diff/impact.
String inDegSuffix(int n) => n > 0 ? ' ·$n⇐' : '';

/// Strips a node id's `kind:` prefix (`file:lib/x.dart` -> `lib/x.dart`,
/// `provider:name` -> `name`) — every verb that prints a bare id needed this.
String bare(String id) => id.substring(id.indexOf(':') + 1);

/// Shared remaining-count budget threaded through the ordered sections of a
/// `--json` record so the TOTAL items emitted across every section is capped
/// at the original `--budget`, not `budget` per section. [truncated] is set
/// once any section is cut short.
class Budget {
  Budget(this.remaining);
  int remaining;
  bool truncated = false;

  List<T> take<T>(List<T> items) {
    if (items.length > remaining) truncated = true;
    final taken = items.take(remaining).toList();
    remaining -= taken.length;
    return taken;
  }
}
