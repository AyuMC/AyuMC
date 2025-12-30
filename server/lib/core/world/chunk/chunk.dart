import 'dart:typed_data';

import 'chunk_section.dart';

/// Represents a 16x16 column of blocks in the world.
///
/// Ultra-optimized implementation:
/// - Lazy section initialization
/// - Pre-computed heightmaps
/// - Efficient encoding for network transmission
class Chunk {
  /// Chunk X coordinate
  final int x;

  /// Chunk Z coordinate
  final int z;

  /// Number of sections (24 for 1.21: Y from -64 to 320)
  static const int kSectionCount = 24;

  /// Minimum Y level
  static const int kMinY = -64;

  /// Maximum Y level
  static const int kMaxY = 320;

  /// Sections array (lazily initialized)
  final List<ChunkSection> _sections;

  /// Pre-computed motion blocking heightmap
  Uint8List? _heightmapMotionBlocking;

  /// Pre-computed world surface heightmap
  Uint8List? _heightmapWorldSurface;

  Chunk({required this.x, required this.z, List<ChunkSection>? sections})
    : _sections = sections ?? _createEmptySections();

  /// Creates empty sections for an air chunk.
  static List<ChunkSection> _createEmptySections() {
    return List.generate(kSectionCount, (_) => ChunkSection.empty());
  }

  /// Returns the section at the given index (0-23).
  ChunkSection getSection(int index) {
    if (index < 0 || index >= kSectionCount) {
      return ChunkSection.empty();
    }
    return _sections[index];
  }

  /// Sets a section at the given index.
  void setSection(int index, ChunkSection section) {
    if (index >= 0 && index < kSectionCount) {
      _sections[index] = section;
      _heightmapMotionBlocking = null;
      _heightmapWorldSurface = null;
    }
  }

  /// Generates a flat world chunk.
  ///
  /// Layers from bottom:
  /// - Bedrock at Y=-64
  /// - Stone Y=-63 to Y=60
  /// - Dirt Y=61 to Y=62
  /// - Grass Y=63
  factory Chunk.flatWorld(int chunkX, int chunkZ) {
    final sections = <ChunkSection>[];

    for (int i = 0; i < kSectionCount; i++) {
      final sectionMinY = kMinY + (i * 16);

      if (sectionMinY == -64) {
        // Bottom section: bedrock layer
        sections.add(ChunkSection.bedrock());
      } else if (sectionMinY >= -48 && sectionMinY < 48) {
        // Stone sections
        sections.add(ChunkSection.stone());
      } else if (sectionMinY == 48) {
        // Top layer: dirt + grass (simplified)
        sections.add(ChunkSection.grass());
      } else {
        // Air sections
        sections.add(ChunkSection.empty());
      }
    }

    return Chunk(x: chunkX, z: chunkZ, sections: sections);
  }

  /// Encodes the chunk data for network transmission.
  Uint8List encodeChunkData() {
    final buffer = BytesBuilder(copy: false);

    // Encode all sections
    for (final section in _sections) {
      buffer.add(section.encode());
    }

    return buffer.toBytes();
  }

  /// Gets the motion blocking heightmap (encoded as packed longs).
  Uint8List getHeightmapMotionBlocking() {
    _heightmapMotionBlocking ??= _computeHeightmap();
    return _heightmapMotionBlocking!;
  }

  /// Gets the world surface heightmap.
  Uint8List getHeightmapWorldSurface() {
    _heightmapWorldSurface ??= _computeHeightmap();
    return _heightmapWorldSurface!;
  }

  /// Computes heightmap for all 256 columns.
  ///
  /// Each entry is 9 bits (for Y values 0-384).
  /// Packed into longs: 7 entries per long.
  Uint8List _computeHeightmap() {
    // 256 entries * 9 bits = 2304 bits = 36 longs + padding = 37 longs
    const longCount = 37;
    final longs = Uint8List(longCount * 8);
    final data = ByteData.view(longs.buffer);

    // For flat world, all heights are 64 (surface level)
    const surfaceHeight = 64 + 64; // Offset from -64

    int bitIndex = 0;
    for (int i = 0; i < 256; i++) {
      final longIndex = bitIndex ~/ 64;
      final bitOffset = bitIndex % 64;

      if (longIndex < longCount) {
        var currentValue = data.getInt64(longIndex * 8, Endian.big);
        currentValue |= (surfaceHeight << bitOffset);
        data.setInt64(longIndex * 8, currentValue, Endian.big);
      }

      bitIndex += 9;
    }

    return longs;
  }
}
