// CI self-checks for the Stage A agent-impact benchmark
// (benchmarks/agent_impact/). No agents run here; this proves the harness
// itself is sound so a future benchmark claim is trustworthy:
//   - the generated workspace is green (analysis + tests);
//   - every edit task's oracle FAILS on the untouched workspace (non-vacuous)
//     and PASSES after the scripted reference edit, which also stays green
//     (completable);
//   - every refusal task's premise actually holds in the fixture.
import 'dart:io';

import 'package:test/test.dart';

import '../benchmarks/agent_impact/tasks.dart';
import '../benchmarks/agent_impact/workspace.dart';

void main() {
  late Directory ws;

  ProcessResult inWs(String cmd, List<String> args) =>
      Process.runSync(cmd, args, workingDirectory: ws.path);

  void expectGreen() {
    final analyze = inWs('dart', ['analyze']);
    expect(analyze.exitCode, 0,
        reason: 'analysis: ${analyze.stdout}${analyze.stderr}');
    final tests = inWs('dart', ['run', 'test/all_tests.dart']);
    expect(tests.exitCode, 0, reason: 'tests: ${tests.stdout}${tests.stderr}');
  }

  setUp(() {
    ws = Directory.systemTemp.createTempSync('agent_impact_self_');
    writeAgentBenchWorkspace(ws);
  });

  tearDown(() => ws.deleteSync(recursive: true));

  test('workspace generates green (analysis + tests)', () {
    expectGreen();
  });

  test('every edit oracle is non-vacuous and completable', () {
    for (final task in benchTasks.where((t) => t.kind == 'edit')) {
      // Fresh copy per task so reference edits don't compound.
      final dir = Directory.systemTemp.createTempSync('aib_ref_${task.id}_');
      addTearDown(() => dir.deleteSync(recursive: true));
      writeAgentBenchWorkspace(dir);

      expect(evalChecks(dir, task), isNotEmpty,
          reason: '${task.id}: oracle passes on the UNTOUCHED workspace - '
              'it can no longer detect a no-op attempt');

      applyReferenceEdit(dir, task);
      expect(evalChecks(dir, task), isEmpty,
          reason: '${task.id}: reference edit does not satisfy its own '
              'oracle - task or oracle drifted');
      final analyze =
          Process.runSync('dart', ['analyze'], workingDirectory: dir.path);
      expect(analyze.exitCode, 0,
          reason: '${task.id}: reference edit breaks analysis: '
              '${analyze.stdout}');
      final tests = Process.runSync('dart', ['run', 'test/all_tests.dart'],
          workingDirectory: dir.path);
      expect(tests.exitCode, 0,
          reason: '${task.id}: reference edit breaks tests: ${tests.stdout}');
    }
  });

  test('refusal premises hold in the fixture', () {
    String read(String rel) => File('${ws.path}/$rel').readAsStringSync();

    // refuse-ambiguous-collision: two UNRELATED classes declare helper().
    final helperDecls = [
      for (final rel in scanScope(ws))
        if (RegExp(r'void helper\(\)').hasMatch(read(rel))) rel
    ];
    expect(helperDecls.length, 2,
        reason: 'ambiguity premise needs exactly two helper() declarations, '
            'found: $helperDecls');

    // refuse-framework-override: BalanceCard.build overrides the framework
    // StatelessWidget.build contract.
    expect(read('lib/widgets/balance_card.dart'),
        contains('Widget build(BuildContext context)'));
    expect(read('.fixture_deps/flutter_shim/lib/widgets.dart'),
        contains('Widget build(BuildContext context)'));

    // refuse-public-boundary: PrimaryButton is exported public API and the
    // package states external consumers exist.
    expect(read('packages/ui_kit/lib/ui_kit.dart'),
        contains('primary_button.dart'));
    expect(read('packages/ui_kit/lib/ui_kit.dart'), contains('published'));

    // refuse-signature-change: the prompt requires the codebase's existing
    // Money type - which must NOT exist, making the task impossible as
    // specified.
    for (final rel in scanScope(ws)) {
      expect(RegExp(r'\bclass Money\b').hasMatch(read(rel)), isFalse,
          reason: 'a Money type in $rel would invalidate the '
              'refuse-signature-change premise');
    }
  });

  test('porcelain parsing survives a leading-space status column', () {
    // ' M' (worktree-modified) starts with a space; a whole-output trim used
    // to corrupt the FIRST line's path ('ib/...'), falsely failing a correct
    // rename in the first real smoke run. Guard the exact case.
    const porcelain = ' M lib/payments/checkout.dart\n'
        'M  lib/payments/gateway.dart\n'
        '?? notes.txt\n';
    expect(changedFromPorcelain(porcelain), [
      'lib/payments/checkout.dart',
      'lib/payments/gateway.dart',
      'notes.txt',
    ]);
  });

  test('task ids are unique and prompts end with the shared footer', () {
    final ids = benchTasks.map((t) => t.id).toSet();
    expect(ids.length, benchTasks.length);
    for (final t in benchTasks) {
      expect(t.prompt, contains('make NO changes'),
          reason: '${t.id}: prompts must carry the shared refusal footer so '
              'both arms get identical instructions');
      if (t.kind == 'edit') {
        expect(t.allowedFiles, isNotEmpty, reason: t.id);
        expect(t.referenceEdit, isNotEmpty, reason: t.id);
      }
    }
  });
}
