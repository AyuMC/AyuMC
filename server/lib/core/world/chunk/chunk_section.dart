import 'dart:typed_data';

/// A 16x16x16 section of blocks within a chunk.
///
/// Ultra-optimized implementation:
/// - Uses single palette for flat worlds (minimal memory)
/// - Supports full palette for complex terrain
/// - Zero-copy encoding for network transmission
class ChunkSection {
  /// Total blocks in a section: 16 * 16 * 16 = 4096
  static const int kBlockCount = 4096;

  /// Bits per entry for single-valued palette
  static const int kBitsPerEntrySingle = 0;

  /// Block count (non-air blocks)
  final int blockCount;

  /// Palette type: 0 = single value, 4-8 = indirect, 15 = direct
  final int bitsPerEntry;

  /// Palette entries (block state IDs)
  final List<int> palette;

  /// Packed block data (only if bitsPerEntry > 0)
  final Uint8List? blockData;

  const ChunkSection({
    required this.blockCount,
    required this.bitsPerEntry,
    required this.palette,
    this.blockData,
  });

  /// Creates an empty air section (ultra-optimized for flat worlds).
  factory ChunkSection.empty() {
    return const ChunkSection(
      blockCount: 0,
      bitsPerEntry: 0,
      palette: [0], // Air block state ID
    );
  }

  /// Creates a section filled with a single block type.
  factory ChunkSection.filled(int blockStateId) {
    return ChunkSection(
      blockCount: blockStateId == 0 ? 0 : kBlockCount,
      bitsPerEntry: 0,
      palette: [blockStateId],
    );
  }

  /// Creates a stone section (for flat world ground).
  factory ChunkSection.stone() => ChunkSection.filled(1);

  /// Creates a grass section (for flat world surface).
  factory ChunkSection.grass() => ChunkSection.filled(9);

  /// Creates a dirt section.
  factory ChunkSection.dirt() => ChunkSection.filled(10);

  /// Creates a bedrock section.
  factory ChunkSection.bedrock() => ChunkSection.filled(79);

  /// Encodes this section for network transmission.
  ///
  /// Format:
  /// - Short: block count
  /// - Byte: bits per entry
  /// - VarInt: palette length (if indirect)
  /// - VarInt[]: palette entries (if indirect)
  /// - VarInt: data array length
  /// - Long[]: packed block data
  Uint8List encode() {
    final buffer = BytesBuilder(copy: false);

    // Block count (short)
    buffer.addByte((blockCount >> 8) & 0xFF);
    buffer.addByte(blockCount & 0xFF);

    // Block states paletted container
    _encodePalettedContainer(buffer);

    // Biomes paletted container (single value: plains = 1)
    _encodeBiomeContainer(buffer);

    return buffer.toBytes();
  }

  void _encodePalettedContainer(BytesBuilder buffer) {
    // Bits per entry
    buffer.addByte(bitsPerEntry);

    if (bitsPerEntry == 0) {
      // Single valued palette
      _writeVarInt(buffer, palette[0]);
      // Data array length = 0
      _writeVarInt(buffer, 0);
    } else {
      // Indirect palette
      _writeVarInt(buffer, palette.length);
      for (final entry in palette) {
        _writeVarInt(buffer, entry);
      }

      // Data array
      if (blockData != null) {
        final longCount = (kBlockCount * bitsPerEntry + 63) ~/ 64;
        _writeVarInt(buffer, longCount);
        buffer.add(blockData!);
      } else {
        _writeVarInt(buffer, 0);
      }
    }
  }

  void _encodeBiomeContainer(BytesBuilder buffer) {
    // Single-valued biome palette (plains = 1)
    buffer.addByte(0); // bits per entry
    _writeVarInt(buffer, 1); // plains biome ID
    _writeVarInt(buffer, 0); // data array length
  }

  void _writeVarInt(BytesBuilder buffer, int value) {
    while ((value & ~0x7F) != 0) {
      buffer.addByte((value & 0x7F) | 0x80);
      value = value >> 7;
    }
    buffer.addByte(value & 0x7F);
  }
}
