import 'dart:collection';
import 'dart:isolate';

import '../logging/server_logger.dart';
import '../config/server_config.dart';
import 'chunk/chunk.dart';
import 'map_dimension.dart';
import 'generation/chunk_encode_pool.dart';

/// Manages all world dimensions and their chunks.
///
/// Ultra-optimized implementation:
/// - LRU cache for recently accessed chunks
/// - Lazy chunk generation
/// - Pre-generated spawn chunks
/// - Multi-threaded chunk loading (future)
class MapManager {
  static const String _tag = 'MapManager';
  static final ServerLogger _logger = ServerLogger();

  /// Maximum chunks to keep in memory per dimension
  static const int kMaxCachedChunks = 1024;

  /// View distance for initial spawn chunks
  static const int kSpawnViewDistance = 4;

  /// Singleton instance
  static final MapManager _instance = MapManager._internal();
  factory MapManager() => _instance;
  MapManager._internal();

  /// Chunk caches per dimension
  final Map<MapDimension, LinkedHashMap<int, Chunk>> _chunkCaches = {
    MapDimension.overworld: LinkedHashMap<int, Chunk>.from({}),
    MapDimension.nether: LinkedHashMap<int, Chunk>.from({}),
    MapDimension.end: LinkedHashMap<int, Chunk>.from({}),
  };

  /// Spawn position per dimension
  final Map<MapDimension, (int, int, int)> _spawnPositions = {
    MapDimension.overworld: (0, 64, 0),
    MapDimension.nether: (0, 64, 0),
    MapDimension.end: (0, 64, 0),
  };

  bool _initialized = false;

  /// Encoded chunk packet cache (LRU) per dimension.
  final Map<MapDimension, LinkedHashMap<int, TransferableTypedData>>
  _encodedChunkCache = {
    MapDimension.overworld: LinkedHashMap<int, TransferableTypedData>.from({}),
    MapDimension.nether: LinkedHashMap<int, TransferableTypedData>.from({}),
    MapDimension.end: LinkedHashMap<int, TransferableTypedData>.from({}),
  };

  /// In-flight encodes to avoid duplicate work (chunkKey -> Future).
  final Map<int, Future<TransferableTypedData>> _inflightEncodes = {};

  /// Initializes the map manager and generates spawn chunks.
  void initialize() {
    if (_initialized) return;

    _logger.info(_tag, 'Initializing MapManager...');

    // Initialize multi-threaded chunk encoding pool.
    if (ServerConfig.kChunkEncodingUseIsolates) {
      // Fire-and-forget: we can still serve sync chunks while pool spins up.
      ChunkEncodePool().initialize();
    }

    // Pre-generate spawn chunks for overworld (sync chunk objects)
    _generateSpawnChunks(MapDimension.overworld);

    _initialized = true;
    _logger.info(_tag, 'MapManager initialized');
  }

  /// Generates spawn area chunks for a dimension.
  void _generateSpawnChunks(MapDimension dimension) {
    final (spawnX, _, spawnZ) = _spawnPositions[dimension]!;
    final centerChunkX = spawnX >> 4;
    final centerChunkZ = spawnZ >> 4;

    int generated = 0;

    for (int dx = -kSpawnViewDistance; dx <= kSpawnViewDistance; dx++) {
      for (int dz = -kSpawnViewDistance; dz <= kSpawnViewDistance; dz++) {
        final chunkX = centerChunkX + dx;
        final chunkZ = centerChunkZ + dz;
        getOrGenerateChunk(dimension, chunkX, chunkZ);
        generated++;
      }
    }

    _logger.info(
      _tag,
      'Generated $generated spawn chunks for ${dimension.name}',
    );
  }

  /// Gets a chunk from cache or generates it.
  Chunk getOrGenerateChunk(MapDimension dimension, int chunkX, int chunkZ) {
    final cache = _chunkCaches[dimension]!;
    final key = _chunkKey(chunkX, chunkZ);

    // Check cache first
    if (cache.containsKey(key)) {
      final chunk = cache.remove(key)!;
      cache[key] = chunk; // Move to end (LRU)
      return chunk;
    }

    // Generate new chunk
    final chunk = _generateChunk(dimension, chunkX, chunkZ);

    // Add to cache with LRU eviction
    if (cache.length >= kMaxCachedChunks) {
      cache.remove(cache.keys.first);
    }
    cache[key] = chunk;

    return chunk;
  }

  /// Gets an encoded (framed) Chunk Data packet for a chunk, using isolate-per-core encoding.
  ///
  /// Uses:
  /// - LRU cache for encoded payloads
  /// - In-flight dedupe to prevent duplicate encodes
  Future<TransferableTypedData> getOrEncodeChunkPacket(
    MapDimension dimension,
    int chunkX,
    int chunkZ,
  ) {
    final key = _chunkKey(chunkX, chunkZ);
    final cache = _encodedChunkCache[dimension]!;

    if (cache.containsKey(key)) {
      final cached = cache.remove(key)!;
      cache[key] = cached;
      return Future.value(cached);
    }

    final inflight = _inflightEncodes[key];
    if (inflight != null) {
      return inflight;
    }

    final future = _encodeChunkPacketInternal(dimension, chunkX, chunkZ);
    _inflightEncodes[key] = future;

    future.whenComplete(() {
      _inflightEncodes.remove(key);
    });

    return future.then((encoded) {
      if (cache.length >= ServerConfig.kMaxEncodedChunkCache) {
        cache.remove(cache.keys.first);
      }
      cache[key] = encoded;
      return encoded;
    });
  }

  Future<TransferableTypedData> _encodeChunkPacketInternal(
    MapDimension dimension,
    int chunkX,
    int chunkZ,
  ) {
    // If pool not initialized yet, it will fallback to main isolate encoding.
    return ChunkEncodePool().encodeFlatChunkPacket(
      dimension: dimension,
      chunkX: chunkX,
      chunkZ: chunkZ,
    );
  }

  /// Generates a chunk for the given position.
  Chunk _generateChunk(MapDimension dimension, int chunkX, int chunkZ) {
    // For now, generate flat world chunks
    // TODO: Implement proper terrain generation
    return Chunk.flatWorld(chunkX, chunkZ);
  }

  /// Gets chunks around a position for initial load.
  List<Chunk> getChunksAroundPosition(
    MapDimension dimension,
    double x,
    double z,
    int viewDistance,
  ) {
    final centerChunkX = (x ~/ 16).toInt();
    final centerChunkZ = (z ~/ 16).toInt();
    final chunks = <Chunk>[];

    // Spiral loading pattern for better UX
    for (int radius = 0; radius <= viewDistance; radius++) {
      for (int dx = -radius; dx <= radius; dx++) {
        for (int dz = -radius; dz <= radius; dz++) {
          // Only add chunks on the current ring
          if (dx.abs() == radius || dz.abs() == radius) {
            chunks.add(
              getOrGenerateChunk(
                dimension,
                centerChunkX + dx,
                centerChunkZ + dz,
              ),
            );
          }
        }
      }
    }

    return chunks;
  }

  /// Gets spawn position for a dimension.
  (int x, int y, int z) getSpawnPosition(MapDimension dimension) {
    return _spawnPositions[dimension]!;
  }

  /// Sets spawn position for a dimension.
  void setSpawnPosition(MapDimension dimension, int x, int y, int z) {
    _spawnPositions[dimension] = (x, y, z);
  }

  /// Returns statistics about cached chunks.
  Map<String, int> getStatistics() {
    return {
      'overworld': _chunkCaches[MapDimension.overworld]!.length,
      'nether': _chunkCaches[MapDimension.nether]!.length,
      'end': _chunkCaches[MapDimension.end]!.length,
    };
  }

  /// Creates a unique key for a chunk position.
  int _chunkKey(int x, int z) {
    return (x & 0xFFFF) << 16 | (z & 0xFFFF);
  }

  /// Clears all cached chunks.
  void clear() {
    for (final cache in _chunkCaches.values) {
      cache.clear();
    }
    for (final cache in _encodedChunkCache.values) {
      cache.clear();
    }
    _inflightEncodes.clear();
  }
}
