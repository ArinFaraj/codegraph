import 'dart:convert';
import 'dart:io';

import 'package:codegraph/src/model.dart';

/// Runs codegraph CLI verbs (--json) and parses item sets for scoring.
class CodegraphArm {
  CodegraphArm(this.root, this.cliSnapshot);

  final Directory root;
  final String cliSnapshot;

  ProcessResult _run(List<String> args) => Process.runSync(
        Platform.resolvedExecutable,
        [cliSnapshot, ...args],
        workingDirectory: root.path,
      );

  ({Set<String> items, int outputChars, int wallMs}) _parseJsonRun(
    List<String> args,
    Set<String> Function(Map<String, dynamic> json) extract,
  ) {
    final sw = Stopwatch()..start();
    final result = _run(args);
    sw.stop();
    final stdout = result.stdout.toString().trim();
    if (result.exitCode != 0 || stdout.isEmpty) {
      return (
        items: <String>{},
        outputChars: 0,
        wallMs: sw.elapsedMilliseconds
      );
    }
    // JSON is last line or whole stdout when stderr mixed — take last `{` block
    final jsonStart = stdout.indexOf('{');
    final jsonEnd = stdout.lastIndexOf('}');
    if (jsonStart < 0 || jsonEnd <= jsonStart) {
      return (
        items: <String>{},
        outputChars: stdout.length,
        wallMs: sw.elapsedMilliseconds,
      );
    }
    final json = jsonDecode(stdout.substring(jsonStart, jsonEnd + 1))
        as Map<String, dynamic>;
    return (
      items: extract(json),
      outputChars: stdout.length,
      wallMs: sw.elapsedMilliseconds,
    );
  }

  ({Set<String> items, int outputChars, int wallMs}) readers(String provider) =>
      _parseJsonRun(
        ['readers', provider, '--json'],
        (j) {
          final out = <String>{};
          for (final r in (j['results'] as List? ?? const [])) {
            final rec = r as Map<String, dynamic>;
            for (final rel in providerInteractionRelOrder) {
              out.addAll((rec[rel] as List? ?? const []).cast<String>());
            }
          }
          return out;
        },
      );

  ({Set<String> items, int outputChars, int wallMs}) find(String query) =>
      _parseJsonRun(
        ['find', query, '--json'],
        (j) {
          final out = <String>{};
          for (final r in (j['results'] as List? ?? const [])) {
            final rec = r as Map<String, dynamic>;
            final id = rec['id'] as String;
            final kind = rec['kind'] as String;
            if (kind == 'file') {
              out.add(id);
            } else if (id.contains(' — ')) {
              out.add(id.split(' — ').last.trim());
            }
          }
          return out;
        },
      );

  ({Set<String> items, int outputChars, int wallMs}) callers(String symbol) =>
      _parseJsonRun(
        ['callers', symbol, '--json'],
        (j) {
          final out = <String>{};
          for (final h in (j['hits'] as List? ?? const [])) {
            final rec = h as Map<String, dynamic>;
            if (rec['kind'] == 'call') {
              out.add('${rec['file']}:${rec['line']}');
            }
          }
          return out;
        },
      );

  ({Set<String> items, int outputChars, int wallMs}) impls(String type) =>
      _parseJsonRun(
        ['impls', type, '--json'],
        (j) {
          final out = <String>{};
          for (final r in (j['results'] as List? ?? const [])) {
            final rec = r as Map<String, dynamic>;
            out.add(rec['file'] as String);
          }
          return out;
        },
      );

  ({Set<String> items, int outputChars, int wallMs}) symImporters(
          String symbol) =>
      _parseJsonRun(
        ['sym', symbol, '--json'],
        (j) {
          final out = <String>{};
          for (final r in (j['results'] as List? ?? const [])) {
            final rec = r as Map<String, dynamic>;
            out.addAll((rec['importedBy'] as List? ?? const []).cast<String>());
          }
          return out;
        },
      );

  ({Set<String> items, int outputChars, int wallMs}) impact(
    String target, {
    int depth = 1,
  }) =>
      _parseJsonRun(
        ['impact', target, '--depth', '$depth', '--json'],
        (j) {
          final out = <String>{};
          for (final level in (j['levels'] as List? ?? const [])) {
            for (final f in (level as List)) {
              final rec = f as Map<String, dynamic>;
              out.add(rec['file'] as String);
            }
          }
          return out;
        },
      );

  /// Returns {'refused'} when the CLI marks any subtype edge of [type]
  /// ambiguous - the shipped surface of the refuse-not-guess doctrine.
  ({Set<String> items, int outputChars, int wallMs}) implsRefusal(
          String type) =>
      _parseJsonRun(
        ['impls', type, '--json'],
        (j) => (j['results'] as List? ?? const [])
                .any((r) => (r as Map)['ambiguous'] == true)
            ? {'refused'}
            : {},
      );

  ({Set<String> items, int outputChars, int wallMs}) untestedProviders() =>
      _parseJsonRun(
        ['untested', '--json'],
        (j) => (j['providers'] as List? ?? const [])
            .map((p) => (p as Map)['name'] as String)
            .toSet(),
      );
}
