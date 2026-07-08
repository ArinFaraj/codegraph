import 'package:codegraph/src/model.dart';

import 'codegraph_arm.dart';
import 'grep_baseline.dart';
import 'metrics.dart';

/// One agent-every-session task: ground truth + both arms.
///
/// GROUND TRUTH IS FROZEN AND HAND-VERIFIED against the fixture source
/// (test/fixture.dart) — it is NOT derived from the built graph. This matters:
/// if truth came from codegraph's own output, an engine regression that dropped
/// a real reader would also drop it from truth, and the benchmark would still
/// show recall 1.0 (the regression stays invisible). Frozen truth turns a miss
/// into a red recall number. When you deliberately change the fixture, update
/// the literal `truth` set here and say why in the same commit.
class UsefulnessScenario {
  const UsefulnessScenario({
    required this.id,
    required this.agentQuestion,
    required this.category,
    required this.truth,
    required this.runCodegraph,
    required this.runGrep,
    this.codegraphToolCalls = 1,
    this.grepToolCalls = 2,
    this.structuralCheck,
  });

  final String id;
  final String agentQuestion;
  final String category;

  /// Frozen, hand-verified expected set — independent of both tools.
  final Set<String> truth;
  final ({Set<String> items, int outputLines, int wallMs}) Function(
    CodegraphArm cg,
    Graph graph,
  ) runCodegraph;
  final Set<String> Function(GrepBaseline grep, Graph graph) runGrep;
  final int codegraphToolCalls;
  final int grepToolCalls;
  final bool Function(Graph graph)? structuralCheck;

  Map<String, dynamic> evaluate({
    required Graph graph,
    required CodegraphArm cg,
    required GrepBaseline grep,
  }) {
    final cgRun = runCodegraph(cg, graph);
    final grepItems = runGrep(grep, graph);
    final cgScore = UsefulnessScore(
      truth: truth,
      found: cgRun.items,
      toolCalls: codegraphToolCalls,
      outputLines: cgRun.outputLines,
      wallMs: cgRun.wallMs,
    );
    final grepScore = UsefulnessScore(
      truth: truth,
      found: grepItems,
      toolCalls: grepToolCalls,
      outputLines: grepItems.length,
    );
    final structural = structuralCheck == null ? null : structuralCheck!(graph);
    return {
      'id': id,
      'category': category,
      'agentQuestion': agentQuestion,
      'codegraph': cgScore.toJson('codegraph'),
      'grep': grepScore.toJson('grep'),
      'winner': _winner(cgScore, grepScore),
      if (structural != null) 'structuralOk': structural,
    };
  }

  String _winner(UsefulnessScore cg, UsefulnessScore grep) {
    if (cg.f1 > grep.f1 + 0.05) return 'codegraph';
    if (grep.f1 > cg.f1 + 0.05) return 'grep';
    if (cg.f1 == grep.f1) {
      if (cg.toolCalls < grep.toolCalls) return 'codegraph (tie, fewer tools)';
      if (grep.toolCalls < cg.toolCalls) return 'grep (tie, fewer tools)';
      return 'tie';
    }
    return 'mixed';
  }
}

/// DupUser (lib/ambig/c/user.dart) extends DupBase, which is declared in TWO
/// files (ambig/a + ambig/b) and imported from neither — the tool must mark the
/// edge ambiguous and refuse a first-wins file, not point confidently at one.
bool _duplicateClassRefused(Graph graph) {
  final matches = graph.edges.where(
    (e) =>
        e.src == 'file:lib/ambig/c/user.dart' && e.rel == 'implements/extends',
  );
  if (matches.isEmpty) return false;
  final edge = matches.first;
  return edge.dst == 'type:DupBase' && edge.ambiguous;
}

final usefulnessScenarios = <UsefulnessScenario>[
  UsefulnessScenario(
    id: 'locate-symbol',
    category: 'locate',
    agentQuestion: 'Where is class HomePage declared?',
    truth: const {'lib/home/home_page.dart'},
    runCodegraph: (cg, _) => cg.find('HomePage'),
    runGrep: (grep, _) => grep.locateSymbol('HomePage'),
    grepToolCalls: 1,
  ),
  UsefulnessScenario(
    id: 'locate-member',
    category: 'locate',
    agentQuestion: 'Where is method render() declared? (SamplePage)',
    truth: const {'lib/features/sample/presentation/sample_page.dart'},
    runCodegraph: (cg, _) => cg.find('render'),
    runGrep: (grep, _) => grep.locateMemberName('render'),
    grepToolCalls: 1,
  ),
  UsefulnessScenario(
    id: 'locate-member-cap',
    category: 'locate',
    agentQuestion: 'Where is method m13() (past 12-member render cap)?',
    truth: const {'lib/sig/many_members.dart'},
    runCodegraph: (cg, _) => cg.find('m13'),
    runGrep: (grep, _) => grep.locateMemberName('m13'),
    grepToolCalls: 1,
  ),
  UsefulnessScenario(
    id: 'provider-readers',
    category: 'wiring',
    agentQuestion: 'Who watches/reads/listens to homeProvider?',
    truth: const {'lib/home/home_page.dart'},
    runCodegraph: (cg, _) => cg.readers('homeProvider'),
    runGrep: (grep, _) => grep.providerReaders('homeProvider'),
    grepToolCalls: 3,
  ),
  UsefulnessScenario(
    id: 'provider-readers-precision',
    category: 'trust',
    agentQuestion:
        'Readers of counterProvider — must EXCLUDE the non-ref `_Bag().listen` '
        'and the bare-token mention (false-positive guard)',
    // Real ref-receiver reads only. non_ref_cascade.dart (a _Bag with a listen
    // method) and barrel_and_chain_importer.dart (bare `counterProvider;` token)
    // must NOT appear — that is the whole point of this scenario.
    truth: const {
      'lib/notif/counter_ref_ext.dart',
      'lib/notif/counter_container_reader.dart',
      'lib/notif/counter_cascade_reader.dart',
    },
    runCodegraph: (cg, _) => cg.readers('counterProvider'),
    runGrep: (grep, _) => grep.providerReaders('counterProvider'),
    grepToolCalls: 3,
  ),
  UsefulnessScenario(
    id: 'call-sites',
    category: 'refs',
    agentQuestion: 'Who CALLS pingTarget (not references / not declaration)?',
    truth: const {'lib/calls/caller_a.dart:2', 'lib/calls/caller_b.dart:3'},
    runCodegraph: (cg, _) => cg.callers('pingTarget'),
    runGrep: (grep, _) => grep.callSitesByName('pingTarget'),
    grepToolCalls: 1,
  ),
  UsefulnessScenario(
    id: 'subtype-tree',
    category: 'hierarchy',
    agentQuestion:
        'Every transitive subtype of Shape (not just direct extends)?',
    truth: const {'lib/sig/shapes.dart'},
    runCodegraph: (cg, _) => cg.impls('Shape'),
    runGrep: (grep, _) => grep.directSubtypesOf('Shape'),
    grepToolCalls: 2,
  ),
  UsefulnessScenario(
    id: 'cross-package-importers',
    category: 'boundary',
    agentQuestion: 'Which lib files import FancyButton from fixture_ui?',
    truth: const {'lib/home/home_page.dart'},
    runCodegraph: (cg, _) => cg.symImporters('FancyButton'),
    runGrep: (grep, _) => grep.importersOfFilePath('fancy_button.dart'),
    grepToolCalls: 2,
  ),
  UsefulnessScenario(
    id: 'impact-one-hop',
    category: 'impact',
    agentQuestion: 'What depends on home_page.dart within 1 hop?',
    truth: const {'lib/impact_area/home_page_importer.dart'},
    runCodegraph: (cg, _) => cg.impact('home_page.dart', depth: 1),
    runGrep: (grep, _) => grep.impactOneHop('home_page.dart'),
    grepToolCalls: 4,
  ),
  UsefulnessScenario(
    id: 'duplicate-provider-readers',
    category: 'wiring',
    agentQuestion: 'Readers of dupProvider (two declarations — both readers)?',
    truth: const {'lib/dup/a_reader.dart', 'lib/dup/b_reader.dart'},
    runCodegraph: (cg, _) => cg.readers('dupProvider'),
    runGrep: (grep, _) => grep.providerReaders('dupProvider'),
    grepToolCalls: 3,
  ),
  UsefulnessScenario(
    id: 'untested-providers',
    category: 'coverage',
    agentQuestion: 'Providers with zero test references in the graph?',
    // Hand-verified against the fixture's test/ roots and the testRef closure
    // doctrine: a bare comment-mention (unreachableProvider) does NOT count;
    // a barrel-reachable ref (barrelGatedProvider) DOES. Everything else with
    // no test/ reference is untested.
    truth: const {
      'budgetProvider',
      'counterProvider',
      'dupProvider',
      'lintBannedProvider',
      'lintMisplacedProvider',
      'partNotImportedProvider',
      'sampleCookieJarProvider',
      'sampleExtPageProvider',
      'sampleExtProvider',
      'sampleRepositoryProvider',
      'unreachableProvider',
    },
    runCodegraph: (cg, _) => cg.untestedProviders(),
    runGrep: (grep, g) => grep.untestedProvidersHeuristic(
      g.nodes.where((n) => n.isProvider).map((n) => n.name!).toList(),
    ),
    grepToolCalls: 15,
  ),
  UsefulnessScenario(
    id: 'ambiguous-class-refusal',
    category: 'trust',
    agentQuestion:
        'DupUser extends DupBase — graph must refuse, not first-wins a file',
    truth: const {'refused'},
    runCodegraph: (_, g) => (
      items: _duplicateClassRefused(g) ? {'refused'} : {},
      outputLines: 1,
      wallMs: 0,
    ),
    runGrep: (_, __) => {'lib/ambig/a/dup_base.dart'},
    codegraphToolCalls: 0,
    grepToolCalls: 1,
    structuralCheck: _duplicateClassRefused,
  ),
];
