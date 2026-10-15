/// One column in one world. This is not the player spatial index.
final class ChunkKey {
  const ChunkKey({required this.worldId, required this.x, required this.z});

  static const overworld = 'overworld';

  final String worldId;
  final int x;
  final int z;

  @override
  bool operator ==(Object other) =>
      other is ChunkKey && other.worldId == worldId && other.x == x && other.z == z;

  @override
  int get hashCode => Object.hash(worldId, x, z);

  @override
  String toString() => 'ChunkKey($worldId, $x, $z)';
}

int chebyshev(int ax, int az, int bx, int bz) {
  final dx = ax - bx;
  final dz = az - bz;
  final adx = dx < 0 ? -dx : dx;
  final adz = dz < 0 ? -dz : dz;
  return adx > adz ? adx : adz;
}

int regionCoord(int chunk) => (chunk / 32).floor();
