import 'dart:io';

import 'package:codegraph/src/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
