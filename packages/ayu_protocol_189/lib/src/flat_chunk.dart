import 'dart:typed_data';

import 'buffer.dart';

/// One 1.8.9 overworld chunk column whose only solid blocks are a stone
/// floor at y = 15. This is a development pad so a client can finish
/// "downloading terrain". It is not a world.
///
/// Section layout for protocol 47: 4096 little-endian unsigned shorts
/// `(id << 4) | meta`, then 2048 block-light nibbles, then 2048 sky-light
/// nibbles. A ground-up packet also carries 256 biome bytes.
Uint8List flatStonePadChunk({required int chunkX, required int chunkZ}) {
  const blocks = 8192;
  const lights = 2048;
  final section = Uint8List(blocks + lights + lights);
  const stone = 1 << 4;
  for (var z = 0; z < 16; z++) {
    for (var x = 0; x < 16; x++) {
      final index = ((15 << 8) | (z << 4) | x) * 2;
      section[index] = stone & 0xFF;
      section[index + 1] = (stone >> 8) & 0xFF;
    }
  }
  section.fillRange(blocks + lights, section.length, 0xFF);
  final data = Uint8List(section.length + 256);
  data.setRange(0, section.length, section);
  data.fillRange(section.length, data.length, 1);
  return encodePacket(0x21, [
    ...encodeInt(chunkX),
    ...encodeInt(chunkZ),
    1,
    0x00, 0x01, // bitmask: section 0 only, big-endian unsigned short
    ...encodeVarInt(data.length),
    ...data,
  ]);
}
