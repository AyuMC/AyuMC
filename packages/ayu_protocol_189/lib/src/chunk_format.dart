import 'dart:typed_data';

import 'buffer.dart';

/// Clientbound Map Chunk Data (0x21) for protocol 47.
///
/// [sections] is the *canonical* concatenation of each present section in
/// bitmask order: 8192 little-endian block shorts, 2048 block-light nibbles,
/// and, when [skylight] is true, 2048 sky-light nibbles. That grouping is
/// how AyuMC stores a column. The 1.8.9 client does not read it that way.
///
/// This encoder transposes the grouped buffer into the order `Chunk.fillChunk`
/// uses for a ground-up packet: every present section's block array, then
/// every block-light array, then every sky-light array, then [biomes]
/// (256 bytes) when [groundUpContinuous] is true. Packet coordinates live
/// here, not in the canonical column payload.
Uint8List encodeChunkColumn({
  required int chunkX,
  required int chunkZ,
  required int primaryBitmask,
  required Uint8List sections,
  required Uint8List biomes,
  bool groundUpContinuous = true,
  bool skylight = true,
}) {
  final data = _protocol47ColumnData(
    primaryBitmask: primaryBitmask,
    sections: sections,
    biomes: biomes,
    groundUpContinuous: groundUpContinuous,
    skylight: skylight,
  );
  return encodePacket(0x21, [
    ...encodeInt(chunkX),
    ...encodeInt(chunkZ),
    groundUpContinuous ? 1 : 0,
    (primaryBitmask >> 8) & 0xFF,
    primaryBitmask & 0xFF,
    ...encodeVarInt(data.length),
    ...data,
  ]);
}

/// Protocol-47 column payload without packet framing.
Uint8List _protocol47ColumnData({
  required int primaryBitmask,
  required Uint8List sections,
  required Uint8List biomes,
  required bool groundUpContinuous,
  required bool skylight,
}) {
  const blockBytes = 8192;
  const lightBytes = 2048;
  final present = _presentSectionCount(primaryBitmask);
  final grouped = blockBytes + lightBytes + (skylight ? lightBytes : 0);
  if (sections.length != present * grouped) {
    throw ArgumentError.value(
      sections.length,
      'sections',
      'expected ${present * grouped} for bitmask $primaryBitmask',
    );
  }
  final blocksTotal = present * blockBytes;
  final lightTotal = present * lightBytes;
  final skyTotal = skylight ? lightTotal : 0;
  final biomeTotal = groundUpContinuous ? biomes.length : 0;
  final data = Uint8List(blocksTotal + lightTotal + skyTotal + biomeTotal);
  var blockOut = 0;
  var blockLightOut = blocksTotal;
  var skyOut = blocksTotal + lightTotal;
  for (var i = 0; i < present; i++) {
    final src = i * grouped;
    data.setRange(blockOut, blockOut + blockBytes, sections, src);
    blockOut += blockBytes;
    data.setRange(
      blockLightOut,
      blockLightOut + lightBytes,
      sections,
      src + blockBytes,
    );
    blockLightOut += lightBytes;
    if (skylight) {
      data.setRange(
        skyOut,
        skyOut + lightBytes,
        sections,
        src + blockBytes + lightBytes,
      );
      skyOut += lightBytes;
    }
  }
  if (groundUpContinuous && biomeTotal != 0) {
    data.setRange(data.length - biomeTotal, data.length, biomes);
  }
  return data;
}

int _presentSectionCount(int bitmask) {
  var n = 0;
  var bits = bitmask & 0xFFFF;
  while (bits != 0) {
    n += bits & 1;
    bits >>= 1;
  }
  return n;
}

/// Protocol-47 unload: ground-up continuous, empty bitmask, size 0.
Uint8List encodeChunkUnload({required int chunkX, required int chunkZ}) {
  return encodePacket(0x21, [
    ...encodeInt(chunkX),
    ...encodeInt(chunkZ),
    1,
    0x00,
    0x00,
    ...encodeVarInt(0),
  ]);
}

/// A decoded 0x21 body. Used by tests and the chunk benchmark client.
final class DecodedChunkColumn {
  const DecodedChunkColumn({
    required this.chunkX,
    required this.chunkZ,
    required this.groundUpContinuous,
    required this.primaryBitmask,
    required this.data,
  });

  final int chunkX;
  final int chunkZ;
  final bool groundUpContinuous;
  final int primaryBitmask;
  final Uint8List data;

  int get presentSections {
    var n = 0;
    var bits = primaryBitmask & 0xFFFF;
    while (bits != 0) {
      n += bits & 1;
      bits >>= 1;
    }
    return n;
  }
}

/// Parses one uncompressed play-state frame whose id is 0x21.
DecodedChunkColumn? decodeChunkColumn(Uint8List frame) {
  final body = PacketBuffer()..add(frame);
  if (body.readVarInt() != 0x21) return null;
  final chunkX = body.readInt();
  final chunkZ = body.readInt();
  final groundUp = body.readUnsignedByte() != 0;
  final bitmask = body.readUnsignedShort();
  final size = body.readVarInt();
  final data = size == 0 ? Uint8List(0) : body.readBytes(size);
  return DecodedChunkColumn(
    chunkX: chunkX,
    chunkZ: chunkZ,
    groundUpContinuous: groundUp,
    primaryBitmask: bitmask,
    data: data,
  );
}
