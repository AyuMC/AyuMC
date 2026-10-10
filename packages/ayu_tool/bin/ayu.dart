import 'dart:io';

import 'package:ayu_tool/ayu_tool.dart';

Future<void> main(List<String> args) async {
  exitCode = await AyuCommandLine().run(args);
}
