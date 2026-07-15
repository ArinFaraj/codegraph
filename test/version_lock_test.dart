import 'dart:io';

import 'package:codegraph/src/version_skew.dart' show binaryVersion;
import 'package:test/test.dart';

void main() {
  test('binaryVersion matches pubspec.yaml version', () {
    // version_skew.dart's binaryVersion is a hand-maintained string literal
    // (an installed snapshot can't read pubspec.yaml at runtime), and it has
    // already drifted from pubspec.yaml once. This is the tripwire that
    // keeps the two values in sync: bump both together, or this fails.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must have a version: line');
    expect(binaryVersion, match!.group(1),
        reason: 'lib/src/version_skew.dart binaryVersion is out of sync '
            'with pubspec.yaml — update both together');
  });
}
