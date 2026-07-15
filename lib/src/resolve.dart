// THE shared file-argument resolver for the query-side verbs. Every verb
// that takes a <file> argument (path/wiring/skeleton/impact/brief) resolves
// it with the same semantics: unique substring match over file node ids,
// else exact-suffix tiebreak (`/arg` or the full bare path), else a typed
// Ambiguous/NotFound refusal. Six per-verb copies had drifted (wiring
// hard-failed on ANY 2+ matches; brief missed the full-path tiebreak) - the
// same argument could resolve in one verb and refuse in another.
//
// Exit-code contract: an [AmbiguousFile] refusal prints the candidate list
// (see [printAmbiguous]) and the verb exits 2 (cannot answer); 0 stays
// "answered" including typed empties; 64 usage; 66 no graph.
import 'dart:io';

import 'cli_util.dart' show bare;
import 'model.dart';

/// Typed result of [resolveFileArg]. Paths are bare (no `file:` prefix).
sealed class FileResolution {}

class ResolvedFile extends FileResolution {
  ResolvedFile(this.path);
  final String path;
}

class AmbiguousFile extends FileResolution {
  AmbiguousFile(this.candidates);
  final List<String> candidates;
}

class NotFoundFile extends FileResolution {}

/// Resolves [arg] against the graph's file nodes: unique substring, else
/// exact-suffix tiebreak (a path ending in `/arg`, or `arg` being the whole
/// bare path), else [AmbiguousFile] with every substring hit, else
/// [NotFoundFile].
FileResolution resolveFileArg(Graph graph, String arg) {
  final hits = graph.nodes
      .where((n) => n.isFile && n.id.contains(arg))
      .map((n) => n.id)
      .toList();
  if (hits.length == 1) return ResolvedFile(bare(hits.first));
  final exact =
      hits.where((h) => h.endsWith('/$arg') || h.endsWith(':$arg')).toList();
  if (exact.length == 1) return ResolvedFile(bare(exact.first));
  if (hits.isNotEmpty) return AmbiguousFile([for (final h in hits) bare(h)]);
  return NotFoundFile();
}

/// The standard ambiguity refusal: header + capped candidate list. Callers
/// return exit code 2 after this.
void printAmbiguous(String arg, List<String> candidates, {int cap = 8}) {
  stdout.writeln('"$arg" is ambiguous (${candidates.length} files):');
  for (final c in candidates.take(cap)) {
    stdout.writeln('  $c');
  }
  if (candidates.length > cap) {
    stdout.writeln('  ... ${candidates.length - cap} more');
  }
}
