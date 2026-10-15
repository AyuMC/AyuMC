import 'dart:typed_data';

import 'payload.dart';
import 'terrain.dart';

/// Feet and block spawn used by protocol-47 join packets.
final class SpawnPoint {
  const SpawnPoint({
    required this.blockX,
    required this.blockY,
    required this.blockZ,
    required this.feetX,
    required this.feetY,
    required this.feetZ,
    this.levelType = 'flat',
  });

  final int blockX;
  final int blockY;
  final int blockZ;
  final double feetX;
  final double feetY;
  final double feetZ;
  final String levelType;
}

/// Pure column generator. No sockets, no storage, no player state.
abstract interface class ChunkGenerator {
  String get id;
  int get version;
  bool get heavy;
  bool get requiresNeighbors;
  SpawnPoint get spawn;
  ChunkPayload generate({required int seed, required int x, required int z});
}

/// Development pad: one stone floor at local y = 15 in section 0.
final class FlatStonePadGenerator implements ChunkGenerator {
  const FlatStonePadGenerator();

  static const idName = 'flat_stone_pad';

  static const SpawnPoint padSpawn = SpawnPoint(
    blockX: 8,
    blockY: 15,
    blockZ: 8,
    feetX: 8.5,
    feetY: 16.0,
    feetZ: 8.5,
  );

  @override
  String get id => idName;

  @override
  int get version => 1;

  @override
  bool get heavy => false;

  @override
  bool get requiresNeighbors => false;

  @override
  SpawnPoint get spawn => padSpawn;

  @override
  ChunkPayload generate({required int seed, required int x, required int z}) {
    final section = Uint8List(ChunkPayload.sectionBytes(true));
    const stone = 1;
    for (var lz = 0; lz < 16; lz++) {
      for (var lx = 0; lx < 16; lx++) {
        writeBlock(section, lx, 15, lz, stone);
      }
    }
    fillSkyLight(section);
    final biomes = Uint8List(ChunkPayload.biomeBytes)..fillRange(0, ChunkPayload.biomeBytes, 1);
    return ChunkPayload(
      primaryBitmask: 0x0001,
      skylight: true,
      biomes: biomes,
      sections: section,
    );
  }
}

/// Test fixture that burns CPU before returning a stone pad.
final class BusyChunkGenerator implements ChunkGenerator {
  const BusyChunkGenerator({this.busyMicros = 2000});

  static const idName = 'busy';

  final int busyMicros;

  @override
  String get id => idName;

  @override
  int get version => 1;

  @override
  bool get heavy => true;

  @override
  bool get requiresNeighbors => false;

  @override
  SpawnPoint get spawn => FlatStonePadGenerator.padSpawn;

  @override
  ChunkPayload generate({required int seed, required int x, required int z}) {
    final clock = Stopwatch()..start();
    var n = 0;
    while (clock.elapsedMicroseconds < busyMicros) {
      n = (n + seed + x + z + clock.elapsedMicroseconds) & 0x7fffffff;
    }
    if (n == -1) {
      throw StateError('unreachable');
    }
    return const FlatStonePadGenerator().generate(seed: seed, x: x, z: z);
  }
}

ChunkGenerator? generatorById(String id) {
  switch (id) {
    case FlatStonePadGenerator.idName:
      return const FlatStonePadGenerator();
    case BusyChunkGenerator.idName:
      return const BusyChunkGenerator();
    case TerrainGeneratorV1.idName:
      return TerrainGeneratorV1();
    default:
      return null;
  }
}
