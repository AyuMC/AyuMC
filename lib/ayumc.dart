/// AyuMC server entry library: a console loop around [AyuServer].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_core/ayu_core.dart';

export 'package:ayu_commands/ayu_commands.dart';
export 'package:ayu_core/ayu_core.dart';

/// Starts the server, serves console commands from stdin until `stop`,
/// then shuts down. Returns the process exit code.
Future<int> runServer({List<String> arguments = const []}) async {
  final server = AyuServer(pluginDirectory: Directory(_pluginDirectoryFrom(arguments)));
  await server.start();

  final done = Completer<void>();
  server.commands.register(Command(
    name: 'stop',
    description: 'Stop the server',
    execute: (_) {
      if (!done.isCompleted) done.complete();
    },
  ));

  // Console lines run strictly in order; EOF stops the server once the
  // queued commands have finished.
  var queue = Future<void>.value();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  final subscription = lines.listen(
    (line) => queue = queue.then((_) => server.commands.execute(line)),
    onDone: () => queue.then((_) {
      if (!done.isCompleted) done.complete();
    }),
  );
  final signals = ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });

  await done.future;
  await signals.cancel();
  await subscription.cancel();
  await server.stop();
  return 0;
}

String _pluginDirectoryFrom(List<String> arguments) {
  final index = arguments.indexOf('--plugins');
  if (index >= 0 && index + 1 < arguments.length) return arguments[index + 1];
  return 'plugins';
}
