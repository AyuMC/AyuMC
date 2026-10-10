import 'dart:io';

import 'package:ayu_manager/ayu_manager.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final root = Directory(p.absolute(_value(arguments, '--root') ?? 'run'));
  final repoArg = _value(arguments, '--repo');
  final repository = repoArg == null
      ? findRepository(root)
      : Directory(p.absolute(repoArg));
  exitCode = await ManagerApp(root: root, repository: repository).run();
}

String? _value(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index >= 0 && index + 1 < arguments.length) return arguments[index + 1];
  return null;
}
