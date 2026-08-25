import 'dart:io';

import 'package:asset_guard/src/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
