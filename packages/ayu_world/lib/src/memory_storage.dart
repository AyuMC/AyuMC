import 'key.dart';
import 'payload.dart';
import 'storage.dart';

final class MemoryChunkStorage implements ChunkStorage {
  final Map<ChunkKey, _Stored> _data = {};
  final Map<ChunkKey, List<int>> quarantined = {};

  @override
  Future<ChunkLookup> lookup(ChunkKey key) async {
    final stored = _data[key];
    if (stored == null) return const ChunkLookup.miss();
    return ChunkLookup.hit(
      payload: stored.payload,
      generatorId: stored.generatorId,
      generatorVersion: stored.generatorVersion,
      regenerable: stored.regenerable,
      playerModified: stored.playerModified,
      finalized: stored.finalized,
    );
  }

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) async {
    _data[key] = _Stored(
      payload: payload,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: regenerable,
      playerModified: playerModified,
      finalized: finalized,
    );
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) async {
    quarantined[key] = List<int>.from(bytes);
    _data.remove(key);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  int get length => _data.length;
}

final class _Stored {
  _Stored({
    required this.payload,
    required this.generatorId,
    required this.generatorVersion,
    required this.regenerable,
    required this.playerModified,
    required this.finalized,
  });

  final ChunkPayload payload;
  final String generatorId;
  final int generatorVersion;
  final bool regenerable;
  final bool playerModified;
  final bool finalized;
}
