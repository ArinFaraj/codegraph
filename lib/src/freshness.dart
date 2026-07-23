// Staleness contract for every query verb: never silently answer from a
// graph that no longer matches the source. The documented trap this kills:
// `find X` returning "(no matches)" for a symbol that plainly exists because
// the graph predates the file - indistinguishable from genuine absence.
//
// Mechanism: build stores a content digest of everything it read
// (engine.sourceDigest, stats.sourceDigest) plus a stat-only digest
// (engine.statDigest, stats.statDigest). loadFresh checks the cheap stat
// digest first; only on mismatch does it pay the full content walk, and on
// content mismatch or missing graph it rebuilds in place with the fast syntax
// extractor. Element-resolution is reserved for the few verbs that need it;
// paying a whole-workspace analyzer pass to answer `find` after every edit
// makes normal navigation unusable in large Flutter apps. stdout stays clean,
// so --json parsing is safe.
// Opt out with the global `--no-rebuild` flag: it skips the digest walk
// ENTIRELY (the walk costs more than most queries), so freshness is unknown
// and every output says "freshness unchecked" instead of claiming fresh.

import 'dart:io';

import 'daemon.dart' as daemon;
import 'engine.dart' as engine;
import 'model.dart';

/// Cleared by the global `--no-rebuild` flag (stripped in bin/codegraph.dart).
bool autoRebuild = true;

/// Whether the graph the current verb is answering from matches the source.
/// True after a fresh load or an auto-rebuild. Meaningless when
/// [freshnessChecked] is false (--no-rebuild skips the digest walk entirely -
/// that is the flag's point: zero freshness overhead for callers that just
/// built). Typed empty results and --json `fresh` read this pair so "not
/// found" can never be mistaken for "not built yet".
bool lastLoadFresh = true;

/// False when the digest walk was skipped (--no-rebuild): freshness is then
/// UNKNOWN, not asserted - output must say "unchecked", never "fresh".
bool freshnessChecked = true;

// The CLI's async preflight and the synchronous verb execute in the same
// process. Once preflight has proved or rebuilt freshness, let the verb consume
// that proof instead of walking every source file a second time.
bool _preflightFresh = false;
String? _preflightWorkspace;

void _markPreflightFresh() {
  _preflightFresh = true;
  _preflightWorkspace = Directory.current.absolute.path;
}

/// CLI freshness preflight: fast syntax refreshes for navigation, resolved
/// refreshes only for element-precise operations.
///
/// The query implementations stay synchronous, so their library-level
/// [loadFresh] fallback remains syntax-only. The async CLI entry point calls
/// this first, then the query's normal [loadFresh] call takes the fresh
/// stat-digest fast path. This avoids converting every query API to Future
/// while ensuring
/// ordinary CLI navigation stays fast after an edit. Element-precise verbs
/// opt into the resolved path through [requireResolved].
Future<void> ensureFreshDefault({bool requireResolved = false}) async {
  _preflightFresh = false;
  _preflightWorkspace = null;
  if (!autoRebuild) return;
  // A healthy worker already tracks filesystem events and serializes refreshes
  // with manual/resolved builds. Ask it first so hot queries avoid walking
  // every source file merely to rediscover that nothing changed.
  if (!requireResolved && await daemon.syncIfRunning()) {
    _markPreflightFresh();
    return;
  }
  if (File('docs/maps/code_graph.json').existsSync()) {
    final graph = Graph.load();
    if (graph == null) return;
    final canResolve = File('.dart_tool/package_config.json').existsSync();
    if (requireResolved && canResolve && graph.stats['resolvedBuild'] != 1) {
      stderr.writeln(
        'graph is syntax-only but resolved dependencies are available - '
        'rebuilding',
      );
      await engine.buildResolvedRuntime();
      _markPreflightFresh();
      return;
    }
    if (graph.stats['statDigest'] == engine.statDigest()) {
      _markPreflightFresh();
      return;
    }
    if (graph.stats['sourceDigest'] == engine.sourceDigest()) {
      _markPreflightFresh();
      return;
    }
    stderr.writeln(
      'graph was stale (source changed since build) - '
      'fast rebuilding${requireResolved ? ' with resolution' : ''}',
    );
  } else {
    stderr.writeln('no graph yet - fast building');
  }
  if (requireResolved) {
    await engine.buildResolvedRuntime();
  } else {
    engine.buildRuntime();
  }
  _markPreflightFresh();
}

/// [Graph.load] plus the staleness contract above. Returns null only when
/// there is no graph and rebuilding is disabled or impossible.
Graph? loadFresh() {
  lastLoadFresh = true;
  freshnessChecked = true;
  if (_preflightFresh &&
      _preflightWorkspace == Directory.current.absolute.path &&
      File('docs/maps/code_graph.json').existsSync()) {
    _preflightFresh = false;
    _preflightWorkspace = null;
    return Graph.load();
  }
  _preflightFresh = false;
  _preflightWorkspace = null;
  if (File('docs/maps/code_graph.json').existsSync()) {
    if (!autoRebuild) {
      // The flag's contract: answer from the graph as-is, paying ZERO
      // freshness cost - no digest walk (it costs more than the query
      // itself). Freshness is therefore unknown, and output says so.
      freshnessChecked = false;
      return Graph.load();
    }
    final graph = Graph.load();
    if (graph == null) return null;
    // Fast path: stat digest (path + length + mtime, no content reads)
    // matches the stored one -> nothing changed on disk since build, fresh.
    if (graph.stats['statDigest'] == engine.statDigest()) return graph;
    // Stat mismatch (or a pre-2.0 graph without statDigest): fall back to the
    // full content digest. Mtime churn without a content change stays fresh
    // here - but a query never writes anything, so a touch-storm keeps paying
    // this content check until the next build refreshes the stored statDigest.
    if (graph.stats['sourceDigest'] == engine.sourceDigest()) return graph;
    stderr.writeln('graph was stale (source changed since build) - rebuilding');
  } else {
    if (!autoRebuild) return Graph.load(); // prints the standard missing note
    stderr.writeln('no graph yet - building');
  }
  engine.buildRuntime();
  return Graph.load();
}
