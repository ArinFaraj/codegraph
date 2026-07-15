// codegraph — analyzer-built code graph + query CLI for AI navigation.
// Repo (fix the engine HERE, not in host projects): see `repoUrl` below.
import 'dart:io';

import 'package:codegraph/src/attention.dart' as attention;
import 'package:codegraph/src/blueprint.dart' as blueprint;
import 'package:codegraph/src/brief.dart' as brief;
import 'package:codegraph/src/callchain.dart' as callchain;
import 'package:codegraph/src/callers.dart' as callers;
import 'package:codegraph/src/diff.dart' as diff;
import 'package:codegraph/src/doctor.dart' as doctor;
import 'package:codegraph/src/engine.dart' as engine;
import 'package:codegraph/src/freshness.dart' as freshness;
import 'package:codegraph/src/impact.dart' as impact;
import 'package:codegraph/src/init.dart' as scaffold;
import 'package:codegraph/src/intent.dart' as intent;
import 'package:codegraph/src/lint.dart' as lint;
import 'package:codegraph/src/query.dart' as query;
import 'package:codegraph/src/rename.dart' as rename;
import 'package:codegraph/src/skeleton.dart' as skeleton;
import 'package:codegraph/src/version_skew.dart' show binaryVersion;

const version = binaryVersion;
const repoUrl = 'https://github.com/ArinFaraj/codegraph';

void _usage() {
  stderr.writeln('''
codegraph $version — code graph for AI navigation ($repoUrl)

start here (intent verbs):
  codegraph find <anything>           what/where is X? files, providers, symbols — ranked by in-degree
  codegraph uses <thing>              who uses X? every inbound relation, sections picked by what X is
  codegraph change <thing>            what breaks? pre-change pack: dependents + subtype tree + test coverage
  codegraph review [--base main]      is my branch safe? changed files, blast radius, untested, lint
  codegraph health                    where is the risk? attention + unused + untested, one card
  codegraph plan <feature-dir>        build-order plan from an exemplar feature (layers, wiring, naming)

operator verbs:
  codegraph build [lib/<area>]        regenerate docs/maps/ (graph + area maps)
  codegraph check                     regen + fail if committed docs/maps/ is stale (CI gate)
  codegraph init [--ci]               install agent scaffolding into this project
  codegraph upgrade                   refresh codegraph-owned scaffolding to this version
  codegraph doctor                    verify the install (hook, gitignore, CLAUDE.md, CI gate)
  codegraph lint                      architecture rules (cross-feature imports, layer order) — CI gate
  codegraph rename <Sym> <new>        element-precise rename (resolved; refuses if unsafe; --apply to write)

low-level verbs (intent verbs compose these):
  sym <Name> | skeleton <file> | brief <thing> | passport
  readers <provider> | provider <name> | callers <Symbol> | refs <Symbol>
  callchain <Symbol> [--depth N] | wiring <file> | impls <Type> | path <A> <B>
  impact <thing> [--depth N] | diff [--base main] | blueprint <feature-dir>
  unused [providers|files|all] | untested | attention

Query flags: --budget N (cap output lines, default 80; brief/diff/health default to 150).
             --json    (find/readers/wiring/impls/sym/skeleton/untested/impact/diff/blueprint: machine-readable output)
             --no-rebuild  (query verbs rebuild a stale/missing graph automatically; this answers from the graph as-is)
Exit codes: 0 answered (incl. typed empties), 2 ambiguous file arg (candidates listed), 64 usage, 66 no graph.
Run from the package root of the host project.''');
}

Future<void> main(List<String> rawArgs) async {
  // Global flag: query verbs auto-rebuild a stale/missing graph by default
  // (freshness.dart); --no-rebuild answers from the graph as-is.
  final args = rawArgs.where((a) => a != '--no-rebuild').toList();
  freshness.autoRebuild = args.length == rawArgs.length;
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    _usage();
    exit(64);
  }
  if (args.first == '--version') {
    stdout.writeln('codegraph $version');
    return;
  }
  switch (args.first) {
    case 'build':
      // v3 default: resolved analysis. Syntax is the automatic zero-setup
      // fallback (no package_config) or the explicit `--syntax` opt-out.
      // Explicit `--resolved` with no package_config refuses (in buildResolved)
      // instead of silently degrading — the user asked for resolved by name.
      final wantSyntax = args.contains('--syntax');
      final hasPkgConfig = File('.dart_tool/package_config.json').existsSync();
      if (!wantSyntax && (args.contains('--resolved') || hasPkgConfig)) {
        await engine.buildResolved(args.skip(1).toList());
      } else {
        if (!wantSyntax) {
          stderr.writeln('note: building syntax-only (no '
              '.dart_tool/package_config.json). Run `dart pub get` for '
              'resolved element analysis.');
        }
        engine.build(args.skip(1).toList());
      }
    case 'check':
      exit(engine.check());
    case 'init':
      scaffold.init(args.skip(1).toList(), version: version, repoUrl: repoUrl);
    case 'upgrade':
      exit(scaffold.upgrade(args.skip(1).toList(),
          version: version, repoUrl: repoUrl));
    case 'skeleton':
      exit(skeleton.run(args));
    case 'brief' || 'passport':
      exit(brief.run(args));
    case 'callers' || 'refs':
      if (args.contains('--resolved')) {
        exit(await callers.runResolved(args));
      }
      exit(callers.run(args));
    case 'rename':
      exit(await rename.run(args));
    case 'callchain':
      exit(callchain.run(args));
    case 'blueprint' || 'plan':
      exit(blueprint.run(args));
    case 'find' ||
          'sym' ||
          'readers' ||
          'provider' ||
          'wiring' ||
          'impls' ||
          'path' ||
          'unused' ||
          'untested':
      exit(query.run(args));
    case 'uses':
      exit(intent.runUses(args));
    case 'change':
      exit(intent.runChange(args));
    case 'health':
      exit(intent.runHealth(args));
    case 'impact':
      exit(impact.run(args));
    // `review` is `diff` under its intent name: the diff card already carries
    // blast radius, changed-but-untested, and lint new-violations.
    case 'diff' || 'review':
      exit(diff.run(args));
    case 'attention':
      exit(attention.run(args));
    case 'lint':
      exit(lint.run(args));
    case 'doctor':
      exit(doctor.run(args));
    default:
      _usage();
      exit(64);
  }
}
