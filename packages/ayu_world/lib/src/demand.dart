import 'key.dart';
import 'pipeline.dart';
import 'ticket.dart';

/// Diffs a holder's required square and issues tickets.
final class ChunkDemand {
  ChunkDemand(this.pipeline, {this.worldId = ChunkKey.overworld});

  final ChunkPipeline pipeline;
  final String worldId;
  final Map<Object, Set<ChunkKey>> _held = {};

  void setPlayerView({
    required Object holder,
    required int chunkX,
    required int chunkZ,
    required int radius,
    bool prefetch = true,
  }) {
    final next = <ChunkKey>{};
    final tickets = <ChunkKey, TicketReason>{};
    for (var dz = -radius; dz <= radius; dz++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final key = ChunkKey(worldId: worldId, x: chunkX + dx, z: chunkZ + dz);
        next.add(key);
        tickets[key] = chebyshev(0, 0, dx, dz) <= 1
            ? TicketReason.p0
            : TicketReason.p1;
      }
    }
    if (prefetch) {
      final ring = radius + 1;
      for (var dz = -ring; dz <= ring; dz++) {
        for (var dx = -ring; dx <= ring; dx++) {
          if (chebyshev(0, 0, dx, dz) != ring) continue;
          final key = ChunkKey(worldId: worldId, x: chunkX + dx, z: chunkZ + dz);
          next.add(key);
          tickets[key] = TicketReason.p2;
        }
      }
    }
    _apply(holder, next, tickets);
  }

  void setKeys(
    Object holder,
    Map<ChunkKey, TicketReason> tickets,
  ) {
    _apply(holder, tickets.keys.toSet(), tickets);
  }

  void clear(Object holder) {
    final previous = _held.remove(holder);
    if (previous == null) return;
    for (final key in previous) {
      pipeline.removeTicket(holder, key);
    }
  }

  void _apply(
    Object holder,
    Set<ChunkKey> next,
    Map<ChunkKey, TicketReason> tickets,
  ) {
    final previous = _held[holder] ?? {};
    for (final key in previous) {
      if (!next.contains(key)) pipeline.removeTicket(holder, key);
    }
    for (final key in next) {
      pipeline.addTicket(holder, key, tickets[key] ?? TicketReason.p1);
    }
    _held[holder] = next;
  }
}
