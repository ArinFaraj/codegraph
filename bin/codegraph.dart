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
import 'package:codegraph/src/impact.dart' as impact;
import 'package:codegraph/src/init.dart' as scaffold;
import 'package:codegraph/src/lint.dart' as lint;
import 'package:codegraph/src/query.dart' as query;
import 'package:codegraph/src/skeleton.dart' as skeleton;
import 'package:codegraph/src/version_skew.dart' show binaryVersion;

const version = binaryVersion;
const repoUrl = 'https://github.com/ArinFaraj/codegraph';

void _usage() {
  stderr.writeln('''
codegraph $version — code graph for AI navigation ($repoUrl)

  codegraph build [lib/<area>]        regenerate docs/maps/ (graph + area maps)
  codegraph check                     regen + fail if committed docs/maps/ is stale (CI gate)
  codegraph init [--ci]               install agent scaffolding into this project
                                      (CLAUDE.md block, SessionStart hook, code-map skill)
  codegraph upgrade                   refresh codegraph-owned scaffolding to this version
                                      (hook, skill, CLAUDE.md block; never host content)
  codegraph doctor                    verify the install (hook, gitignore, CLAUDE.md, CI gate)

  codegraph brief <thing>             one-shot context card: provider, area, file, or symbol
  codegraph blueprint <feature-dir>   build-order plan from an exemplar feature (layers, wiring, naming)
  codegraph passport                  session digest: counts, top areas/files/providers
  codegraph diff [--base main]        branch blast-radius card — what changed, what it touches, what's untested
  codegraph impact <thing> [--depth N]  transitive dependents (what breaks if this changes)

  codegraph find <substr> [more terms]  locate files, providers, symbols — ranked by in-degree
  codegraph sym <Name>                symbol card: sig + doc + members + imported-by
  codegraph skeleton <file>           per-file outline (declarations + line numbers)
  codegraph readers <provider>        who watches/reads/listens a provider
  codegraph callers <Symbol>          every call site (file:line) of a method/function — incl. tests
  codegraph refs <Symbol>             every reference (calls + tear-offs + type/case uses)
  codegraph callchain <Symbol> [--depth N]  static call tree + control-flow hazard flags (what runs / where it skips)
  codegraph provider <name>           declaration + all consumers
  codegraph wiring <file>             a file's full wiring, both directions
  codegraph impls <Type>              who implements/extends a type
  codegraph path <A> <B>              shortest connection between two files
  codegraph unused [providers|files|all]  dead-code candidates
  codegraph untested                  coverage gaps: providers/files with zero test references
  codegraph attention                 triage surface (same sections as docs/maps/ATTENTION.md)
  codegraph lint                      architecture rules (cross-feature imports, layer order) — CI gate

Query flags: --budget N (cap output lines, default 80; brief defaults to 150).
             --json    (find/readers/wiring/impls/sym/skeleton/untested/impact/diff/blueprint: machine-readable output)
Run from the package root of the host project.''');
}

void main(List<String> args) {
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
      engine.build(args.skip(1).toList());
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
      exit(callers.run(args));
    case 'callchain':
      exit(callchain.run(args));
    case 'blueprint':
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
    case 'impact':
      exit(impact.run(args));
    case 'diff':
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
