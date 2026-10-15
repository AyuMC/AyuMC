import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test('the stone pad has one section, stone at y=15, full sky, plains', () {
    final payload = const FlatStonePadGenerator().generate(
      seed: 123,
      x: 4,
      z: -7,
    );
    expect(payload.primaryBitmask, 1);
    expect(payload.skylight, isTrue);
    expect(payload.presentSections, 1);
    expect(payload.sections.length, ChunkPayload.sectionBytes(true));
    expect(payload.biomes.every((b) => b == 1), isTrue);
    for (var z = 0; z < 16; z++) {
      for (var x = 0; x < 16; x++) {
        final index = ((15 << 8) | (z << 4) | x) * 2;
        expect(payload.sections[index], 1 << 4);
        expect(payload.sections[index + 1], 0);
      }
    }
    expect(
      payload.sections.sublist(
        ChunkPayload.blockBytes,
        ChunkPayload.blockBytes + ChunkPayload.lightBytes,
      ),
      everyElement(0),
    );
    expect(
      payload.sections.sublist(
        ChunkPayload.blockBytes + ChunkPayload.lightBytes,
      ),
      everyElement(0xFF),
    );
  });

  test('pack and unpack round-trip', () {
    final original = const FlatStonePadGenerator().generate(
      seed: 0,
      x: 0,
      z: 0,
    );
    final packed = original.pack();
    final restored = ChunkPayload.unpack(packed);
    expect(restored.primaryBitmask, original.primaryBitmask);
    expect(restored.skylight, original.skylight);
    expect(restored.biomes, original.biomes);
    expect(restored.sections, original.sections);
  });

  test('spawn matches the protocol-47 stone pad', () {
    const spawn = FlatStonePadGenerator.padSpawn;
    expect(spawn.blockX, 8);
    expect(spawn.blockY, 15);
    expect(spawn.blockZ, 8);
    expect(spawn.feetX, 8.5);
    expect(spawn.feetY, 16.0);
    expect(spawn.feetZ, 8.5);
    expect(spawn.levelType, 'flat');
  });

  test('ChunkKey equality does not pack like the player index', () {
    const a = ChunkKey(worldId: 'overworld', x: 1, z: 2);
    const b = ChunkKey(worldId: 'overworld', x: 1, z: 2);
    const c = ChunkKey(worldId: 'nether', x: 1, z: 2);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
    expect(regionCoord(-1), -1);
    expect(regionCoord(32), 1);
    expect(chebyshev(0, 0, 3, -2), 3);
  });
}
