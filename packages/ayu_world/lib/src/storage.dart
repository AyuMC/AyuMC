import 'key.dart';
import 'payload.dart';

enum ChunkLookupKind { hit, miss, corrupt }

final class ChunkLookup {
  const ChunkLookup.hit({
    required this.payload,
    required this.generatorId,
    required this.generatorVersion,
    required this.regenerable,
    required this.playerModified,
    required this.finalized,
  }) : kind = ChunkLookupKind.hit,
       raw = null;

  const ChunkLookup.miss()
      : kind = ChunkLookupKind.miss,
        payload = null,
        generatorId = null,
        generatorVersion = null,
        regenerable = true,
        playerModified = false,
        finalized = false,
        raw = null;

  const ChunkLookup.corrupt({
    required this.playerModified,
    this.raw,
  }) : kind = ChunkLookupKind.corrupt,
       payload = null,
       generatorId = null,
       generatorVersion = null,
       regenerable = false,
       finalized = false;

  final ChunkLookupKind kind;
  final ChunkPayload? payload;
  final String? generatorId;
  final int? generatorVersion;
  final bool regenerable;
  final bool playerModified;
  final bool finalized;
  final List<int>? raw;
}

abstract interface class ChunkStorage {
  Future<ChunkLookup> lookup(ChunkKey key);

  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  });

  Future<void> quarantine(ChunkKey key, List<int> bytes);

  Future<void> flush();

  Future<void> close();
}
