import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test('a multi-section 0x21 packet matches the 1.8.9 fillChunk layout', () {
    final payload = _identifiableColumn();
    final packet = encodeChunkColumn(
      chunkX: 3,
      chunkZ: -2,
      primaryBitmask: payload.primaryBitmask,
      sections: payload.sections,
      biomes: payload.biomes,
      skylight: payload.skylight,
    );
    final column = ClientColumn.parse(packet);
    expect(column.chunkX, 3);
    expect(column.chunkZ, -2);
    expect(column.groundUp, isTrue);
    expect(column.bitmask, 0x0095);
    expect(column.present, 4);
    expect(column.dataLength, 4 * 8192 + 4 * 2048 + 4 * 2048 + 256);
    expect(column.blockBytesEnd, 4 * 8192);
    expect(column.blockLightEnd, 4 * 8192 + 4 * 2048);
    expect(column.skyLightEnd, 4 * 8192 + 4 * 2048 + 4 * 2048);
    expect(column.biomeStart, column.skyLightEnd);

    expect(column.blockId(1, 5, 2), 1);
    expect(column.blockMeta(1, 5, 2), 0);
    expect(column.blockId(4, 40, 7), 3);
    expect(column.blockMeta(4, 40, 7), 1);
    expect(column.blockId(8, 64, 1), 9);
    expect(column.blockId(15, 70, 0), 2);
    expect(column.blockId(0, 120, 15), 12);
    expect(column.blockId(0, 16, 0), 0);
    expect(column.blockId(0, 48, 0), 0);

    expect(column.blockLight(4, 40, 7), 4);
    expect(column.skyLight(1, 5, 2), 7);
    expect(column.skyLight(0, 120, 15), 11);
    expect(column.biome(1, 2), 16);
    expect(column.biome(0, 15), 1);
  });

  test('grouped section bytes are not the 1.8.9 client layout', () {
    final payload = _identifiableColumn();
    final grouped = Uint8List(payload.sections.length + payload.biomes.length);
    grouped.setRange(0, payload.sections.length, payload.sections);
    grouped.setRange(payload.sections.length, grouped.length, payload.biomes);
    final wrong = encodePacket(0x21, [
      ...encodeInt(0),
      ...encodeInt(0),
      1,
      (payload.primaryBitmask >> 8) & 0xFF,
      payload.primaryBitmask & 0xFF,
      ...encodeVarInt(grouped.length),
      ...grouped,
    ]);
    final misread = ClientColumn.parse(wrong);
    expect(misread.blockId(1, 5, 2), 1);
    expect(misread.blockId(0, 120, 15), isNot(12));
    expect(misread.blockId(15, 70, 0), isNot(2));
  });

  test('a single section still matches the stone-pad oracle', () {
    final payload = const FlatStonePadGenerator().generate(seed: 0, x: 0, z: 0);
    final packet = encodeChunkColumn(
      chunkX: 0,
      chunkZ: 0,
      primaryBitmask: payload.primaryBitmask,
      sections: payload.sections,
      biomes: payload.biomes,
      skylight: payload.skylight,
    );
    expect(packet, flatStonePadChunk(chunkX: 0, chunkZ: 0));
    final column = ClientColumn.parse(packet);
    expect(column.bitmask, 1);
    expect(column.present, 1);
    expect(column.blockId(8, 15, 8), 1);
    expect(column.blockId(8, 16, 8), 0);
    expect(column.skyLight(8, 15, 8), 15);
  });

  test('seed 42 terrain columns round-trip through an independent decoder', () {
    final generator = TerrainGeneratorV1();
    const seed = 42;
    const chunks = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1)];
    for (final cell in chunks) {
      final payload = generator.generate(seed: seed, x: cell.$1, z: cell.$2);
      expect(payload.presentSections, greaterThanOrEqualTo(2));
      final packet = encodeChunkColumn(
        chunkX: cell.$1,
        chunkZ: cell.$2,
        primaryBitmask: payload.primaryBitmask,
        sections: payload.sections,
        biomes: payload.biomes,
        skylight: payload.skylight,
      );
      final column = ClientColumn.parse(packet);
      expect(column.chunkX, cell.$1);
      expect(column.chunkZ, cell.$2);
      expect(column.bitmask, payload.primaryBitmask);
      expect(column.present, payload.presentSections);
      expect(
        column.dataLength,
        payload.presentSections * 8192 +
            payload.presentSections * 2048 +
            payload.presentSections * 2048 +
            256,
      );
      for (var lz = 0; lz < 16; lz += 5) {
        for (var lx = 0; lx < 16; lx += 5) {
          for (final y in [0, 1, 16, 32, 48, 64, 80, 96, 112, 128]) {
            expect(
              column.blockId(lx, y, lz),
              readBlockId(payload, lx, y, lz),
              reason: '($lx,$y,$lz) in chunk ${cell.$1},${cell.$2}',
            );
          }
        }
      }
    }
  });

  test(
    'spawn Y agrees with the independently decoded standing column',
    () async {
      final pipeline = ChunkPipeline(
        generator: TerrainGeneratorV1(),
        seed: 42,
        config: const ChunkConfig(workers: 0),
      );
      addTearDown(pipeline.close);
      final found = await findSafeSpawn(pipeline);
      expect(found.fallback, isFalse);
      final key = ChunkKey(
        worldId: ChunkKey.overworld,
        x: found.chunkX,
        z: found.chunkZ,
      );
      pipeline.addTicket(Object(), key, TicketReason.p0);
      await pipeline.settle();
      final payload = pipeline.record(key)!.payload!;
      final packet = encodeChunkColumn(
        chunkX: found.chunkX,
        chunkZ: found.chunkZ,
        primaryBitmask: payload.primaryBitmask,
        sections: payload.sections,
        biomes: payload.biomes,
        skylight: payload.skylight,
      );
      final column = ClientColumn.parse(packet);
      final lx = found.spawn.blockX - found.chunkX * 16;
      final lz = found.spawn.blockZ - found.chunkZ * 16;
      final y = found.spawn.blockY;
      expect(column.chunkX, found.chunkX);
      expect(column.chunkZ, found.chunkZ);
      expect(column.blockId(lx, y, lz), readBlockId(payload, lx, y, lz));
      expect(
        column.blockId(lx, y, lz),
        anyOf(TerrainGeneratorV1.grass, TerrainGeneratorV1.sand),
      );
      expect(column.blockId(lx, y + 1, lz), 0);
      expect(column.blockId(lx, y + 2, lz), 0);
      expect(found.spawn.feetY, y + 1.0);
    },
  );
}

ChunkPayload _identifiableColumn() {
  const bitmask = 0x0095;
  final size = ChunkPayload.sectionBytes(true);
  final sections = Uint8List(4 * size);
  final biomes = Uint8List(256);
  _putBlock(sections, bitmask, 1, 5, 2, 1);
  _putBlock(sections, bitmask, 4, 40, 7, 3, 1);
  _putBlock(sections, bitmask, 8, 64, 1, 9);
  _putBlock(sections, bitmask, 15, 70, 0, 2);
  _putBlock(sections, bitmask, 0, 120, 15, 12);
  _putNibble(sections, bitmask, blockLight: true, x: 4, y: 40, z: 7, value: 4);
  _putNibble(sections, bitmask, blockLight: false, x: 1, y: 5, z: 2, value: 7);
  _putNibble(
    sections,
    bitmask,
    blockLight: false,
    x: 0,
    y: 120,
    z: 15,
    value: 11,
  );
  biomes[(2 << 4) | 1] = 16;
  biomes[(15 << 4) | 0] = 1;
  return ChunkPayload(
    primaryBitmask: bitmask,
    skylight: true,
    biomes: biomes,
    sections: sections,
  );
}

void _putBlock(
  Uint8List sections,
  int bitmask,
  int x,
  int y,
  int z,
  int id, [
  int meta = 0,
]) {
  final size = ChunkPayload.sectionBytes(true);
  final index =
      _presentOffset(bitmask, y) * size + (((y & 15) << 8) | (z << 4) | x) * 2;
  final value = (id << 4) | (meta & 0xF);
  sections[index] = value & 0xFF;
  sections[index + 1] = (value >> 8) & 0xFF;
}

void _putNibble(
  Uint8List sections,
  int bitmask, {
  required bool blockLight,
  required int x,
  required int y,
  required int z,
  required int value,
}) {
  final size = ChunkPayload.sectionBytes(true);
  final blockIndex = ((y & 15) << 8) | (z << 4) | x;
  final extra = blockLight
      ? ChunkPayload.blockBytes
      : ChunkPayload.blockBytes + ChunkPayload.lightBytes;
  final byteIndex =
      _presentOffset(bitmask, y) * size + extra + (blockIndex >> 1);
  final nibble = value & 0xF;
  if ((blockIndex & 1) == 0) {
    sections[byteIndex] = (sections[byteIndex] & 0xF0) | nibble;
  } else {
    sections[byteIndex] = (sections[byteIndex] & 0x0F) | (nibble << 4);
  }
}

int _presentOffset(int bitmask, int y) {
  final section = y >> 4;
  var present = 0;
  for (var s = 0; s < section; s++) {
    if (bitmask & (1 << s) != 0) present++;
  }
  return present;
}

/// Layout-independent 1.8.9 column reader. Walks all block arrays, then all
/// block-light arrays, then all sky-light arrays, then biomes. It does not
/// call the production encoder's transpose.
final class ClientColumn {
  ClientColumn({
    required this.chunkX,
    required this.chunkZ,
    required this.groundUp,
    required this.bitmask,
    required this.dataLength,
    required this.blocks,
    required this.blockLights,
    required this.skyLights,
    required this.biomes,
  });

  final int chunkX;
  final int chunkZ;
  final bool groundUp;
  final int bitmask;
  final int dataLength;
  final Uint8List blocks;
  final Uint8List blockLights;
  final Uint8List skyLights;
  final Uint8List biomes;

  static const blockBytes = 8192;
  static const lightBytes = 2048;
  static const biomeBytes = 256;

  int get present {
    var n = 0;
    var bits = bitmask & 0xFFFF;
    while (bits != 0) {
      n += bits & 1;
      bits >>= 1;
    }
    return n;
  }

  int get blockBytesEnd => present * blockBytes;
  int get blockLightEnd => blockBytesEnd + present * lightBytes;
  int get skyLightEnd => blockLightEnd + present * lightBytes;
  int get biomeStart => skyLightEnd;

  static ClientColumn parse(Uint8List packet, {bool skylight = true}) {
    final frame = (PacketBuffer()..add(packet)).readFrame()!;
    final body = PacketBuffer()..add(frame);
    if (body.readVarInt() != 0x21) {
      throw StateError('expected packet 0x21');
    }
    final chunkX = body.readInt();
    final chunkZ = body.readInt();
    final groundUp = body.readUnsignedByte() != 0;
    final bitmask = body.readUnsignedShort();
    final size = body.readVarInt();
    final data = size == 0 ? Uint8List(0) : body.readBytes(size);
    var n = 0;
    var bits = bitmask & 0xFFFF;
    while (bits != 0) {
      n += bits & 1;
      bits >>= 1;
    }
    var cursor = 0;
    final blocks = data.sublist(cursor, cursor + n * blockBytes);
    cursor += n * blockBytes;
    final blockLights = data.sublist(cursor, cursor + n * lightBytes);
    cursor += n * lightBytes;
    final skyLights = skylight
        ? data.sublist(cursor, cursor + n * lightBytes)
        : Uint8List(0);
    if (skylight) cursor += n * lightBytes;
    final biomes = groundUp
        ? data.sublist(cursor, cursor + biomeBytes)
        : Uint8List(0);
    if (groundUp) cursor += biomeBytes;
    if (cursor != size) {
      throw StateError('column data length $size != layout cursor $cursor');
    }
    return ClientColumn(
      chunkX: chunkX,
      chunkZ: chunkZ,
      groundUp: groundUp,
      bitmask: bitmask,
      dataLength: size,
      blocks: blocks,
      blockLights: blockLights,
      skyLights: skyLights,
      biomes: biomes,
    );
  }

  int blockState(int x, int y, int z) {
    final index = _sectionIndex(y);
    if (index == null) return 0;
    final blockIndex = ((y & 15) << 8) | (z << 4) | x;
    final offset = index * blockBytes + blockIndex * 2;
    return blocks[offset] | (blocks[offset + 1] << 8);
  }

  int blockId(int x, int y, int z) => blockState(x, y, z) >> 4;

  int blockMeta(int x, int y, int z) => blockState(x, y, z) & 0xF;

  int blockLight(int x, int y, int z) => _nibble(blockLights, x, y, z);

  int skyLight(int x, int y, int z) => _nibble(skyLights, x, y, z);

  int biome(int x, int z) => biomes[(z << 4) | x];

  int _nibble(Uint8List array, int x, int y, int z) {
    final index = _sectionIndex(y);
    if (index == null) return 0;
    final blockIndex = ((y & 15) << 8) | (z << 4) | x;
    final offset = index * lightBytes + (blockIndex >> 1);
    final byte = array[offset];
    return (blockIndex & 1) == 0 ? byte & 0xF : (byte >> 4) & 0xF;
  }

  int? _sectionIndex(int y) {
    final section = y >> 4;
    if (section < 0 || section > 15) return null;
    if ((bitmask & (1 << section)) == 0) return null;
    var present = 0;
    for (var s = 0; s < section; s++) {
      if (bitmask & (1 << s) != 0) present++;
    }
    return present;
  }
}
