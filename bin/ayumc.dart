import 'dart:io';

import 'package:ayumc/ayumc.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runServer(arguments: arguments);
}
