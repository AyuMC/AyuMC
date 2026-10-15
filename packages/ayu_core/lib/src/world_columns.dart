import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_world/ayu_world.dart';

final class WorldColumnSource implements ChunkColumnSource {
  WorldColumnSource(this.engine) {
    engine.pipeline.addReadyListener(_onReady);
  }

  final WorldEngine engine;
  final List<void Function(int chunkX, int chunkZ)> _listeners = [];

  @override
  void acquire(
    Object holder,
    int chunkX,
    int chunkZ, {
    required int band,
    int? priorityRing,
  }) {
    final reason =
        TicketReason.values[band.clamp(0, TicketReason.values.length - 1)];
    engine.pipeline.addTicket(
      holder,
      ChunkKey(worldId: engine.profile.worldId, x: chunkX, z: chunkZ),
      reason,
      priorityRing: priorityRing,
    );
  }

  @override
  void release(Object holder, int chunkX, int chunkZ) {
    engine.pipeline.removeTicket(
      holder,
      ChunkKey(worldId: engine.profile.worldId, x: chunkX, z: chunkZ),
    );
  }

  @override
  void releaseAll(Object holder) => engine.pipeline.releaseAll(holder);

  @override
  Uint8List? encoded(int chunkX, int chunkZ) => engine.encoded(chunkX, chunkZ);

  @override
  void addReadyListener(void Function(int chunkX, int chunkZ) listener) {
    _listeners.add(listener);
  }

  @override
  void removeReadyListener(void Function(int chunkX, int chunkZ) listener) {
    _listeners.remove(listener);
  }

  void _onReady(ChunkKey key) {
    for (final listener in List.of(_listeners)) {
      listener(key.x, key.z);
    }
  }

  void close() {
    engine.pipeline.removeReadyListener(_onReady);
    _listeners.clear();
  }
}
