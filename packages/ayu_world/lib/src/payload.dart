import 'dart:typed_data';

/// Canonical 1.8.9 column. Not a protocol packet: coordinates and framing
/// are added by the encoder.
final class ChunkPayload {
  ChunkPayload({
    required this.primaryBitmask,
    required this.skylight,
    required this.biomes,
    required this.sections,
    this.formatVersion = currentFormat,
  }) {
    if (biomes.length != biomeBytes) {
      throw ArgumentError.value(biomes.length, 'biomes', 'must be $biomeBytes');
    }
    final expected = presentSections * sectionBytes(skylight);
    if (sections.length != expected) {
      throw ArgumentError.value(
        sections.length,
        'sections',
        'expected $expected for bitmask $primaryBitmask',
      );
    }
  }

  static const currentFormat = 1;
  static const biomeBytes = 256;
  static const blockBytes = 8192;
  static const lightBytes = 2048;
  static const maxPackedBytes = 1 << 20;

  static int sectionBytes(bool skylight) =>
      blockBytes + lightBytes + (skylight ? lightBytes : 0);

  static int countSections(int bitmask) {
    var n = 0;
    var bits = bitmask & 0xFFFF;
    while (bits != 0) {
      n += bits & 1;
      bits >>= 1;
    }
    return n;
  }

  final int formatVersion;
  final int primaryBitmask;
  final bool skylight;
  final Uint8List biomes;
  final Uint8List sections;

  int get presentSections => countSections(primaryBitmask);

  int get byteLength => 4 + biomeBytes + sections.length;

  /// Packed form used by storage and worker isolates.
  Uint8List pack() {
    final out = Uint8List(4 + biomeBytes + sections.length);
    out[0] = formatVersion;
    out[1] = skylight ? 1 : 0;
    out[2] = (primaryBitmask >> 8) & 0xFF;
    out[3] = primaryBitmask & 0xFF;
    out.setRange(4, 4 + biomeBytes, biomes);
    out.setRange(4 + biomeBytes, out.length, sections);
    return out;
  }

  static ChunkPayload unpack(Uint8List bytes) {
    if (bytes.length < 4 + biomeBytes) {
      throw const FormatException('chunk payload is truncated');
    }
    final format = bytes[0];
    if (format != currentFormat) {
      throw FormatException('unsupported chunk payload format $format');
    }
    final skylight = bytes[1] != 0;
    final bitmask = (bytes[2] << 8) | bytes[3];
    final biomes = Uint8List(biomeBytes)..setRange(0, biomeBytes, bytes, 4);
    final sections = Uint8List(bytes.length - 4 - biomeBytes)
      ..setRange(0, bytes.length - 4 - biomeBytes, bytes, 4 + biomeBytes);
    return ChunkPayload(
      formatVersion: format,
      primaryBitmask: bitmask,
      skylight: skylight,
      biomes: biomes,
      sections: sections,
    );
  }
}

void writeBlock(Uint8List section, int x, int y, int z, int id, [int meta = 0]) {
  final index = ((y << 8) | (z << 4) | x) * 2;
  final value = (id << 4) | (meta & 0xF);
  section[index] = value & 0xFF;
  section[index + 1] = (value >> 8) & 0xFF;
}

void fillSkyLight(Uint8List section) {
  section.fillRange(
    ChunkPayload.blockBytes + ChunkPayload.lightBytes,
    section.length,
    0xFF,
  );
}

/// Sky-light nibble for one block in a multi-section buffer. [size] is one
/// section's byte length. Even block indexes use the low nibble.
void writeSkyLightNibble(
  Uint8List sections,
  int size,
  int x,
  int y,
  int z,
  int value,
) {
  final section = y >> 4;
  final blockIndex = ((y & 15) << 8) | (z << 4) | x;
  final byteIndex =
      section * size + ChunkPayload.blockBytes + ChunkPayload.lightBytes + (blockIndex >> 1);
  final nibble = value & 0xF;
  if ((blockIndex & 1) == 0) {
    sections[byteIndex] = (sections[byteIndex] & 0xF0) | nibble;
  } else {
    sections[byteIndex] = (sections[byteIndex] & 0x0F) | (nibble << 4);
  }
}

int readSkyLightNibble(ChunkPayload payload, int x, int y, int z) {
  final offset = _sectionOffset(payload, y);
  if (offset == null) return 15;
  final blockIndex = ((y & 15) << 8) | (z << 4) | x;
  final byteIndex = offset + ChunkPayload.blockBytes + ChunkPayload.lightBytes + (blockIndex >> 1);
  final byte = payload.sections[byteIndex];
  return (blockIndex & 1) == 0 ? byte & 0xF : (byte >> 4) & 0xF;
}

/// Protocol-47 block id at local column ([x], [z]) and world [y], or 0 if that
/// section is absent.
int readBlockId(ChunkPayload payload, int x, int y, int z) {
  if (y < 0 || y > 255) return 0;
  final offset = _sectionOffset(payload, y);
  if (offset == null) return 0;
  final index = offset + (((y & 15) << 8) | (z << 4) | x) * 2;
  return (payload.sections[index] | (payload.sections[index + 1] << 8)) >> 4;
}

int? _sectionOffset(ChunkPayload payload, int y) {
  final section = y >> 4;
  if (section < 0 || section > 15) return null;
  if ((payload.primaryBitmask & (1 << section)) == 0) return null;
  var present = 0;
  for (var s = 0; s < section; s++) {
    if (payload.primaryBitmask & (1 << s) != 0) present++;
  }
  return present * ChunkPayload.sectionBytes(payload.skylight);
}
