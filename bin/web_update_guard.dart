import 'dart:io';

import 'package:web_update_guard/stamper.dart';

/// Entry point for `dart run web_update_guard`.
void main(List<String> arguments) {
  exitCode = runCli(arguments);
}
