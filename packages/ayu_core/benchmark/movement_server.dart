// Server process for the movement benchmark. Clients run in another process.
// stdout lines that start with "AYU " are the control channel. Logs stay off
// that channel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_core/ayu_core.dart';
import 'package:ayu_logging/ayu_logging.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: movement_server.dart <server-root>');
    exitCode = 1;
    return;
  }
  LogHub.echo = false;
  await runZonedGuarded(() => _serve(Directory(args.first)), (error, stack) {
    stderr.writeln('AYU ignored $error');
  });
}

Future<void> _serve(Directory root) async {
  final server = AyuServer(rootDirectory: root);
  await server.start();
  final port = server.network?.port;
  if (port == null) {
    stderr.writeln('AYU failed to bind');
    await server.stop();
    exitCode = 1;
    return;
  }
  stdout.writeln('AYU ready port=$port pid=$pid');
  final done = Completer<void>();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  final subscription = lines.listen((line) {
    if (line == 'stats') {
      final network = server.network;
      stdout.writeln(
        'AYU stats ${jsonEncode({
          'accepted': network?.acceptedMovementPackets ?? 0,
          'encodes': network?.replicationEncodes ?? 0,
          'deliveries': network?.replicationDeliveries ?? 0,
          'bytes': network?.replicationBytes ?? 0,
          'sessions': network?.sessions.length ?? 0,
          'spawns': network?.entitySpawns ?? 0,
          'destroys': network?.entityDestroys ?? 0,
          'gapMaxMicros': network?.inboundGapMaxMicros ?? 0,
          'delayMaxMicros': network?.replicationDelayMaxMicros ?? 0,
          'chunkDeliveries': network?.chunkDeliveries ?? 0,
          'chunkBytes': network?.chunkBytes ?? 0,
          'chunkQueue': network?.chunkQueueDepth ?? 0,
          'chunkUnloads': network?.chunkUnloads ?? 0,
          ...?server.world?.stats(),
        })}',
      );
    } else if (line == 'stop') {
      if (!done.isCompleted) done.complete();
    }
  });
  await done.future;
  await subscription.cancel();
  await server.stop();
  stdout.writeln('AYU stopped');
}
