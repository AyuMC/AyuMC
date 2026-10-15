import 'generator.dart';
import 'key.dart';
import 'payload.dart';
import 'pipeline.dart';
import 'terrain.dart';
import 'ticket.dart';

final class SpawnSearch {
  const SpawnSearch({
    required this.spawn,
    required this.fallback,
    required this.chunkX,
    required this.chunkZ,
  });

  final SpawnPoint spawn;
  final bool fallback;
  final int chunkX;
  final int chunkZ;
}

/// Walks a spiral of at most [maxChunks] columns from the origin and picks a
/// dry grass surface first, then a dry sand surface. A candidate must have
/// air at the feet and head, a solid block below, and must not treat water as
/// air. The fallback stands on the highest solid or water block of chunk
/// (0, 0) at local (8, 8).
Future<SpawnSearch> findSafeSpawn(
  ChunkPipeline pipeline, {
  int maxChunks = 32,
  String worldId = ChunkKey.overworld,
}) async {
  final holder = Object();
  try {
    (int, int, int, int, int)? sandHit;
    var i = 0;
    for (final cell in _spiral()) {
      if (i >= maxChunks) break;
      i++;
      final payload = await _column(
        pipeline,
        holder,
        worldId,
        cell.$1,
        cell.$2,
      );
      final grass = _surface(payload, TerrainGeneratorV1.grass);
      if (grass != null) {
        return _hit(cell.$1, cell.$2, grass, fallback: false);
      }
      if (sandHit == null) {
        final sand = _surface(payload, TerrainGeneratorV1.sand);
        if (sand != null) {
          sandHit = (cell.$1, cell.$2, sand.$1, sand.$2, sand.$3);
        }
      }
    }
    if (sandHit != null) {
      return _hit(sandHit.$1, sandHit.$2, (
        sandHit.$3,
        sandHit.$4,
        sandHit.$5,
      ), fallback: false);
    }
    final origin = await _column(pipeline, holder, worldId, 0, 0);
    final y = _highestStand(origin, 8, 8);
    return SpawnSearch(
      spawn: SpawnPoint(
        blockX: 8,
        blockY: y,
        blockZ: 8,
        feetX: 8.5,
        feetY: y + 1.0,
        feetZ: 8.5,
        levelType: 'default',
      ),
      fallback: true,
      chunkX: 0,
      chunkZ: 0,
    );
  } finally {
    pipeline.releaseAll(holder);
  }
}

SpawnSearch _hit(
  int chunkX,
  int chunkZ,
  (int, int, int) local, {
  required bool fallback,
}) {
  final blockX = chunkX * 16 + local.$1;
  final blockZ = chunkZ * 16 + local.$3;
  return SpawnSearch(
    spawn: SpawnPoint(
      blockX: blockX,
      blockY: local.$2,
      blockZ: blockZ,
      feetX: blockX + 0.5,
      feetY: local.$2 + 1.0,
      feetZ: blockZ + 0.5,
      levelType: 'default',
    ),
    fallback: fallback,
    chunkX: chunkX,
    chunkZ: chunkZ,
  );
}

Future<ChunkPayload> _column(
  ChunkPipeline pipeline,
  Object holder,
  String worldId,
  int x,
  int z,
) async {
  final key = ChunkKey(worldId: worldId, x: x, z: z);
  pipeline.addTicket(holder, key, TicketReason.p0);
  await pipeline.settle();
  final payload = pipeline.record(key)?.payload;
  if (payload == null) {
    throw StateError('spawn column ($x, $z) did not become resident');
  }
  return payload;
}

(int, int, int)? _surface(ChunkPayload payload, int want) {
  for (var lz = 0; lz < 16; lz++) {
    for (var lx = 0; lx < 16; lx++) {
      final y = _drySurface(payload, lx, lz, want);
      if (y != null) return (lx, y, lz);
    }
  }
  return null;
}

int? _drySurface(ChunkPayload payload, int lx, int lz, int want) {
  for (var y = 254; y >= 1; y--) {
    if (readBlockId(payload, lx, y, lz) != want) continue;
    if (readBlockId(payload, lx, y + 1, lz) != 0) continue;
    if (readBlockId(payload, lx, y + 2, lz) != 0) continue;
    if (y > 1 && !_solid(readBlockId(payload, lx, y - 1, lz))) continue;
    return y;
  }
  return null;
}

int _highestStand(ChunkPayload payload, int lx, int lz) {
  for (var y = 255; y >= 0; y--) {
    final id = readBlockId(payload, lx, y, lz);
    if (_solid(id) || id == TerrainGeneratorV1.water) return y;
  }
  return 0;
}

bool _solid(int id) =>
    id == TerrainGeneratorV1.stone ||
    id == TerrainGeneratorV1.grass ||
    id == TerrainGeneratorV1.dirt ||
    id == TerrainGeneratorV1.bedrock ||
    id == TerrainGeneratorV1.sand;

Iterable<(int, int)> _spiral() sync* {
  var x = 0;
  var z = 0;
  yield (x, z);
  var dx = 0;
  var dz = -1;
  for (var i = 0; i < 64; i++) {
    if (x == z || (x < 0 && x == -z) || (x > 0 && x == 1 - z)) {
      final t = dx;
      dx = -dz;
      dz = t;
    }
    x += dx;
    z += dz;
    yield (x, z);
  }
}
