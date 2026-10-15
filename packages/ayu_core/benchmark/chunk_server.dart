// Server process for chunk-engine benchmarks. Clients run separately.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_core/ayu_core.dart';
import 'package:ayu_logging/ayu_logging.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: chunk_server.dart <server-root>');
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
      stdout.writeln(
        'AYU stats ${jsonEncode({
          'accepted': server.network?.acceptedMovementPackets ?? 0,
          'sessions': server.network?.sessions.length ?? 0,
          'chunkDeliveries': server.network?.chunkDeliveries ?? 0,
          'chunkBytes': server.network?.chunkBytes ?? 0,
          'chunkQueue': server.network?.chunkQueueDepth ?? 0,
          'chunkUnloads': server.network?.chunkUnloads ?? 0,
          'rss': ProcessInfo.currentRss,
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
