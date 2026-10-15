import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test('the column encoder matches the stone-pad oracle at (0, 0)', () {
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
  });

  test('the column encoder keeps caller coordinates', () {
    final payload = const FlatStonePadGenerator().generate(
      seed: 0,
      x: 3,
      z: -4,
    );
    final packet = encodeChunkColumn(
      chunkX: 3,
      chunkZ: -4,
      primaryBitmask: payload.primaryBitmask,
      sections: payload.sections,
      biomes: payload.biomes,
      skylight: payload.skylight,
    );
    expect(packet, flatStonePadChunk(chunkX: 3, chunkZ: -4));
    final decoded = decodeChunkColumn(
      (PacketBuffer()..add(packet)).readFrame()!,
    )!;
    expect(decoded.chunkX, 3);
    expect(decoded.chunkZ, -4);
    expect(decoded.groundUpContinuous, isTrue);
    expect(decoded.primaryBitmask, 1);
    expect(decoded.data.length, 12544);
  });

  test('unload is a ground-up 0x21 with an empty bitmask', () {
    final packet = encodeChunkUnload(chunkX: 2, chunkZ: -1);
    final frame = (PacketBuffer()..add(packet)).readFrame()!;
    final decoded = decodeChunkColumn(frame)!;
    expect(decoded.chunkX, 2);
    expect(decoded.chunkZ, -1);
    expect(decoded.groundUpContinuous, isTrue);
    expect(decoded.primaryBitmask, 0);
    expect(decoded.data, isEmpty);
  });
}
