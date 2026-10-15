import 'play_session.dart';

/// Chooses which play sessions receive another session's entity packets.
///
/// The core evaluates this on the engine isolate while handling a socket.
/// Plugin workers are not on this path.
abstract interface class PlayerVisibility {
  bool sees({required PlaySession viewer, required PlaySession subject});
}

/// Every announced play session sees every other session.
///
/// Kept for tests and for a deliberate small-world mode. Cost grows with the
/// number of sessions.
final class AllSessionsVisible implements PlayerVisibility {
  const AllSessionsVisible();

  @override
  bool sees({required PlaySession viewer, required PlaySession subject}) =>
      !identical(viewer, subject);
}

/// Horizontal chunk index. This is not terrain storage.
///
/// A cell is 16 by 16 blocks, matching Minecraft's chunk width. Negative
/// coordinates use floor division, so -0.1 belongs to chunk -1.
int chunkCoord(double block) => (block / 16.0).floor();

/// View-distance tracking.
///
/// Vanilla 1.8's server `view-distance` defaults to 10 chunks. The 1.8.9
/// client settings packet reports the client's slider in chunks, normally
/// 2 through 32. The radius used here is the smaller of the server cap and
/// that client value, converted with 16 blocks per chunk. Players see each
/// other when their 3D separation is within both of those radii. Same-chunk
/// membership is not the rule. The chunk map only limits the search to cells
/// that can intersect the radius.
final class ViewDistanceVisibility implements PlayerVisibility {
  const ViewDistanceVisibility({this.serverChunks = defaultServerChunks});

  /// Balanced server view cap for new installations. Vanilla 1.8 defaults to
  /// 10; AyuMC ships 6 after the streaming benchmark showed the last rings of
  /// a radius-10 square dominate time-to-visible-terrain while adding little
  /// to what a player can see while walking. Existing files that set 10 keep
  /// 10 until an operator chooses the new default.
  static const defaultServerChunks = 6;

  /// Lowest and highest values the 1.8 client slider sends.
  static const minChunks = 2;
  static const maxChunks = 32;

  /// Lowest and highest value the configuration center accepts for the
  /// server-side cap. Above this, one player's join dominates the engine and
  /// the send queue, so the cap is a safety limit, not a slider.
  static const minServerChunks = 2;
  static const maxServerChunks = 16;

  final int serverChunks;

  /// The configured value clamped into the supported server range.
  int get effectiveServerChunks =>
      serverChunks.clamp(minServerChunks, maxServerChunks);

  int chunksFor(PlaySession session) {
    final server = effectiveServerChunks;
    final client = (session.clientViewChunks ?? server).clamp(
      minChunks,
      maxChunks,
    );
    return client < server ? client : server;
  }

  int blocksFor(PlaySession session) => chunksFor(session) * 16;

  /// How many chunk cells around a player can contain someone they might see.
  int get searchRadiusChunks => effectiveServerChunks + 1;

  ViewDistanceVisibility withServerChunks(int chunks) =>
      ViewDistanceVisibility(serverChunks: chunks);

  @override
  bool sees({required PlaySession viewer, required PlaySession subject}) {
    if (identical(viewer, subject)) return false;
    final viewerBlocks = blocksFor(viewer);
    final subjectBlocks = blocksFor(subject);
    final blocks = viewerBlocks < subjectBlocks ? viewerBlocks : subjectBlocks;
    final dx = viewer.x - subject.x;
    final dy = viewer.y - subject.y;
    final dz = viewer.z - subject.z;
    return dx * dx + dy * dy + dz * dz <= blocks * blocks;
  }
}

/// Players grouped by horizontal chunk. Lookup cost follows the number of
/// players in the nearby cells, not the number of players on the server.
final class ChunkIndex<T> {
  final Map<int, Set<T>> _cells = {};
  final Map<T, int> _placed = {};

  static int _key(int chunkX, int chunkZ) => (chunkX << 32) ^ chunkZ;

  void move(T item, int chunkX, int chunkZ) {
    final next = _key(chunkX, chunkZ);
    final previous = _placed[item];
    if (previous == next) return;
    if (previous != null) {
      final cell = _cells[previous];
      cell?.remove(item);
      if (cell != null && cell.isEmpty) _cells.remove(previous);
    }
    _cells.putIfAbsent(next, () => <T>{}).add(item);
    _placed[item] = next;
  }

  void remove(T item) {
    final previous = _placed.remove(item);
    if (previous == null) return;
    final cell = _cells[previous];
    cell?.remove(item);
    if (cell != null && cell.isEmpty) _cells.remove(previous);
  }

  Iterable<T> around(int chunkX, int chunkZ, int radius) sync* {
    for (var dz = -radius; dz <= radius; dz++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final cell = _cells[_key(chunkX + dx, chunkZ + dz)];
        if (cell == null) continue;
        for (final item in cell) {
          yield item;
        }
      }
    }
  }
}
