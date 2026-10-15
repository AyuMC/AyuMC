import 'dart:isolate';

import 'generator.dart';

/// Top-level isolate entry. Does not receive sockets or world objects.
void serveChunkWorker(SendPort owner) {
  final incoming = ReceivePort();
  owner.send({'op': 'ready', 'port': incoming.sendPort});
  incoming.listen((message) {
    if (message is! Map) return;
    final map = message.cast<String, Object?>();
    if (map['op'] != 'generate') return;
    final epoch = map['epoch'] as int;
    final worldId = map['worldId'] as String;
    final x = map['x'] as int;
    final z = map['z'] as int;
    final seed = map['seed'] as int;
    final generatorId = map['generatorId'] as String;
    final transferableBytes = map['transferableBytes'] as int? ?? 32768;
    final clock = Stopwatch()..start();
    try {
      final generator = generatorById(generatorId);
      if (generator == null) {
        owner.send({
          'op': 'result',
          'epoch': epoch,
          'worldId': worldId,
          'x': x,
          'z': z,
          'error': 'unknown generator $generatorId',
          'cpuMicros': clock.elapsedMicroseconds,
        });
        return;
      }
      final payload = generator.generate(seed: seed, x: x, z: z);
      final packed = payload.pack();
      Object bytes;
      if (packed.length >= transferableBytes) {
        bytes = TransferableTypedData.fromList([packed]);
      } else {
        bytes = packed;
      }
      owner.send({
        'op': 'result',
        'epoch': epoch,
        'worldId': worldId,
        'x': x,
        'z': z,
        'cpuMicros': clock.elapsedMicroseconds,
        'payload': bytes,
      });
    } catch (error) {
      owner.send({
        'op': 'result',
        'epoch': epoch,
        'worldId': worldId,
        'x': x,
        'z': z,
        'error': error.toString(),
        'cpuMicros': clock.elapsedMicroseconds,
      });
    }
  });
}
