// Stage A agent-impact benchmark: the eight tasks and their oracles.
//
// Honesty rules (benchmarks/README.md) apply: oracles are frozen, hand-written
// postconditions - regex checks over the workspace source plus git cleanliness,
// computed IN CODE, never by an LLM judge. Both arms run the identical task
// prompts; the arms differ only in whether codegraph is available in the
// environment.
//
// Edit tasks also carry a scripted referenceEdit used by the CI self-test to
// prove the task is completable and the oracle non-vacuous (untouched
// workspace must FAIL the oracle; reference-edited workspace must PASS it and
// stay green).
import 'dart:io';

class OracleCheck {
  const OracleCheck.mustMatch(this.pattern, {this.file}) : mustExist = true;
  const OracleCheck.mustNotMatch(this.pattern, {this.file}) : mustExist = false;

  /// Regex applied to source text. [file] scopes the check to one
  /// workspace-relative path; null means every scanned source file.
  final String pattern;
  final String? file;
  final bool mustExist;
}

class BenchTask {
  const BenchTask({
    required this.id,
    required this.kind,
    required this.prompt,
    this.checks = const [],
    this.allowedFiles = const {},
    this.referenceEdit = const {},
  });

  final String id;

  /// 'edit' (oracle = checks + diff scope + green) or 'refusal'
  /// (oracle = working tree unchanged + still green).
  final String kind;
  final String prompt;
  final List<OracleCheck> checks;

  /// Workspace-relative paths an edit task is allowed to touch. Any change
  /// outside this set (or any new untracked file) is an unrelated edit and
  /// fails the attempt. Ignored for refusal tasks (no change is allowed).
  final Set<String> allowedFiles;

  /// file -> ordered (from-regex, to) replacements proving completability.
  final Map<String, List<(String, String)>> referenceEdit;
}

const _footer = '\n\nWork autonomously; do not ask questions. Verify your work '
    'with `dart analyze` and `dart run test/all_tests.dart` before finishing. '
    'If the request is ambiguous, unsafe, or cannot be completed correctly and '
    'completely, make NO changes to the repository and instead explain why in '
    'your final message.';

final List<BenchTask> benchTasks = [
  BenchTask(
    id: 'rename-standalone-fn',
    kind: 'edit',
    prompt: 'Rename the top-level function formatUserName to '
        'formatDisplayName everywhere it is declared and used. Do not '
        'change any other API.'
        '$_footer',
    checks: const [
      OracleCheck.mustNotMatch(r'\bformatUserName\b'),
      OracleCheck.mustMatch(r'String formatDisplayName\(',
          file: 'lib/core/format.dart'),
      OracleCheck.mustMatch(r'formatDisplayName\(',
          file: 'lib/auth/login_screen.dart'),
      OracleCheck.mustMatch(r'formatDisplayName\(',
          file: 'test/format_test.dart'),
    ],
    allowedFiles: const {
      'lib/core/format.dart',
      'lib/auth/login_screen.dart',
      'test/format_test.dart',
    },
    referenceEdit: const {
      'lib/core/format.dart': [(r'\bformatUserName\b', 'formatDisplayName')],
      'lib/auth/login_screen.dart': [
        (r'\bformatUserName\b', 'formatDisplayName')
      ],
      'test/format_test.dart': [(r'\bformatUserName\b', 'formatDisplayName')],
    },
  ),
  BenchTask(
    id: 'rename-private-helper',
    kind: 'edit',
    prompt: 'In lib/core/strings.dart, rename the private function _normalize '
        'to _canonicalize. The file '
        'lib/features/orders/order_utils.dart contains an UNRELATED '
        'private function that happens to share the name; it must not be '
        'touched.'
        '$_footer',
    checks: const [
      OracleCheck.mustNotMatch(r'\b_normalize\b',
          file: 'lib/core/strings.dart'),
      OracleCheck.mustMatch(r'String _canonicalize\(',
          file: 'lib/core/strings.dart'),
      OracleCheck.mustMatch(r'\b_normalize\(',
          file: 'lib/features/orders/order_utils.dart'),
    ],
    allowedFiles: const {'lib/core/strings.dart'},
    referenceEdit: const {
      'lib/core/strings.dart': [(r'\b_normalize\b', '_canonicalize')],
    },
  ),
  BenchTask(
    id: 'rename-provider-pair',
    kind: 'edit',
    prompt: 'Rename the auth state pair: the class SessionNotifier to '
        'AccountNotifier, and the provider sessionProvider to '
        'accountProvider, everywhere they are declared and used '
        '(including tests).'
        '$_footer',
    checks: const [
      OracleCheck.mustNotMatch(r'\bSessionNotifier\b'),
      OracleCheck.mustNotMatch(r'\bsessionProvider\b'),
      OracleCheck.mustMatch(r'class AccountNotifier\b',
          file: 'lib/auth/session.dart'),
      OracleCheck.mustMatch(r'final accountProvider\b',
          file: 'lib/auth/session.dart'),
      OracleCheck.mustMatch(r'\baccountProvider\b',
          file: 'lib/auth/login_screen.dart'),
      OracleCheck.mustMatch(r'\baccountProvider\b',
          file: 'test/session_test.dart'),
    ],
    allowedFiles: const {
      'lib/auth/session.dart',
      'lib/auth/login_screen.dart',
      'test/session_test.dart',
    },
    referenceEdit: const {
      'lib/auth/session.dart': [
        (r'\bSessionNotifier\b', 'AccountNotifier'),
        (r'\bsessionProvider\b', 'accountProvider'),
      ],
      'lib/auth/login_screen.dart': [
        (r'\bsessionProvider\b', 'accountProvider')
      ],
      'test/session_test.dart': [
        (r'\bSessionNotifier\b', 'AccountNotifier'),
        (r'\bsessionProvider\b', 'accountProvider'),
      ],
    },
  ),
  BenchTask(
    id: 'rename-interface-method',
    kind: 'edit',
    prompt: 'Rename the method charge to processCharge across the '
        'PaymentGateway contract, every implementation (production and '
        'test fakes), and every call site.'
        '$_footer',
    checks: const [
      OracleCheck.mustNotMatch(r'\bcharge\('),
      OracleCheck.mustMatch(r'Receipt processCharge\(',
          file: 'lib/payments/gateway.dart'),
      OracleCheck.mustMatch(r'processCharge\(',
          file: 'lib/payments/stripe_gateway.dart'),
      OracleCheck.mustMatch(r'processCharge\(', file: 'test/fake_gateway.dart'),
      OracleCheck.mustMatch(r'\.processCharge\(',
          file: 'lib/payments/checkout.dart'),
    ],
    allowedFiles: const {
      'lib/payments/gateway.dart',
      'lib/payments/stripe_gateway.dart',
      'lib/payments/checkout.dart',
      'test/fake_gateway.dart',
    },
    referenceEdit: const {
      'lib/payments/gateway.dart': [(r'\bcharge\(', 'processCharge(')],
      'lib/payments/stripe_gateway.dart': [(r'\bcharge\(', 'processCharge(')],
      'lib/payments/checkout.dart': [(r'\bcharge\(', 'processCharge(')],
      'test/fake_gateway.dart': [(r'\bcharge\(', 'processCharge(')],
    },
  ),
  BenchTask(
    id: 'refuse-ambiguous-collision',
    kind: 'refusal',
    prompt: 'Rename the method helper to warmUp.$_footer',
  ),
  BenchTask(
    id: 'refuse-framework-override',
    kind: 'refusal',
    prompt: 'Rename the build method of BalanceCard '
        '(lib/widgets/balance_card.dart) to render.'
        '$_footer',
  ),
  BenchTask(
    id: 'refuse-public-boundary',
    kind: 'refusal',
    prompt: 'Rename the public class PrimaryButton in packages/ui_kit to '
        'BrandButton everywhere, ensuring that no consumer of ui_kit '
        'breaks. Note: ui_kit is published on pub.dev and is used by '
        'other applications that are not in this repository.'
        '$_footer',
  ),
  BenchTask(
    id: 'refuse-signature-change',
    kind: 'refusal',
    prompt: 'Change PaymentGateway.charge to accept the codebase\'s existing '
        'Money value type instead of an int amountCents '
        '(charge(Money amount)), updating all implementations and call '
        'sites accordingly.'
        '$_footer',
  ),
];

// ---------------------------------------------------------------------------
// Oracle evaluation (shared by the runner and the CI self-test).
// ---------------------------------------------------------------------------

/// Workspace-relative source paths in oracle scope: the app, local packages,
/// and tests. Shims and generated dirs are out of scope.
List<String> scanScope(Directory root) {
  final out = <String>[];
  for (final top in ['lib', 'packages', 'test']) {
    final d = Directory('${root.path}/$top');
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      out.add(f.path.substring(root.path.length + 1));
    }
  }
  return out..sort();
}

/// Evaluates an edit task's postconditions. Returns failure reasons, empty on
/// pass. Does NOT include diff-scope or green checks (runner-side, they need
/// git and process runs).
List<String> evalChecks(Directory root, BenchTask task) {
  final failures = <String>[];
  final scope = scanScope(root);
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();
  for (final c in task.checks) {
    final re = RegExp(c.pattern);
    if (c.file != null) {
      final f = File('${root.path}/${c.file}');
      final text = f.existsSync() ? read(c.file!) : '';
      final hit = re.hasMatch(text);
      if (hit != c.mustExist) {
        failures.add('${c.file}: ${c.mustExist ? 'missing' : 'still has'} '
            '/${c.pattern}/');
      }
    } else {
      final hits = [
        for (final rel in scope)
          if (re.hasMatch(read(rel))) rel
      ];
      if (c.mustExist && hits.isEmpty) {
        failures.add('nowhere matches /${c.pattern}/');
      }
      if (!c.mustExist && hits.isNotEmpty) {
        failures.add('still matches /${c.pattern}/ in: ${hits.join(', ')}');
      }
    }
  }
  return failures;
}

/// Parses `git status --porcelain` output into changed workspace-relative
/// paths. Do NOT trim the whole output first: the two status columns may
/// legitimately START with a space (' M path'), and a global trim corrupts the
/// first line's path - found by the first real smoke run, which scored a
/// correct rename as an unrelated edit to 'ib/payments/checkout.dart'.
List<String> changedFromPorcelain(String porcelain) => [
      for (final line in porcelain.split('\n'))
        if (line.length > 3 && line.trim().isNotEmpty) line.substring(3).trim(),
    ];

/// Applies an edit task's scripted reference edit (self-test only).
void applyReferenceEdit(Directory root, BenchTask task) {
  for (final entry in task.referenceEdit.entries) {
    final f = File('${root.path}/${entry.key}');
    var text = f.readAsStringSync();
    for (final (from, to) in entry.value) {
      text = text.replaceAll(RegExp(from), to);
    }
    f.writeAsStringSync(text);
  }
}
