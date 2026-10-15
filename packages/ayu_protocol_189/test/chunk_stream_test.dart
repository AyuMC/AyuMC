import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the streamer sends standing before farther columns and unloads on leave',
    () {
      final source = _FakeSource();
      final sent = <DecodedChunkColumn>[];
      final session = ChunkStreamSession(
        holder: Object(),
        source: source,
        write: (packet, {required bool unload}) {
          sent.add(
            decodeChunkColumn((PacketBuffer()..add(packet)).readFrame()!)!,
          );
        },
        isFlushPending: () => false,
        beginFlush: () {},
      );
      session.updateView(chunkX: 0, chunkZ: 0, radius: 1, prefetch: false);
      expect(session.standingReady, isTrue);
      session.sendSlice(1024 * 1024);
      expect(sent.first.chunkX, 0);
      expect(sent.first.chunkZ, 0);
      expect(sent.length, 9);
      session.updateView(chunkX: 4, chunkZ: 0, radius: 1, prefetch: false);
      session.sendSlice(1024 * 1024);
      expect(sent.any((c) => c.primaryBitmask == 0 && c.chunkX == 0), isTrue);
    },
  );

  test('a column left before it is handed off is not transmitted', () {
    final source = _FakeSource();
    final sent = <DecodedChunkColumn>[];
    final session = ChunkStreamSession(
      holder: Object(),
      source: source,
      write: (packet, {required bool unload}) {
        sent.add(
          decodeChunkColumn((PacketBuffer()..add(packet)).readFrame()!)!,
        );
      },
      isFlushPending: () => false,
      beginFlush: () {},
    );
    session.updateView(chunkX: 0, chunkZ: 0, radius: 1, prefetch: false);
    session.updateView(chunkX: 4, chunkZ: 0, radius: 1, prefetch: false);
    session.sendSlice(1024 * 1024);
    expect(sent, isNotEmpty);
    expect(sent.every((column) => column.chunkX >= 3), isTrue);
    expect(
      sent.any((column) => column.primaryBitmask != 0 && column.chunkX == 0),
      isFalse,
    );
  });

  test('view square uses the min of server and client chunks', () {
    expect(viewSquareRadius(serverChunks: 10, clientViewChunks: null), 10);
    expect(viewSquareRadius(serverChunks: 10, clientViewChunks: 2), 2);
  });
}

final class _FakeSource implements ChunkColumnSource {
  final payload = const FlatStonePadGenerator().generate(seed: 0, x: 0, z: 0);
  final Map<(int, int), Uint8List> packets = {};
  int encodes = 0;

  @override
  void acquire(
    Object holder,
    int chunkX,
    int chunkZ, {
    required int band,
    int? priorityRing,
  }) {}

  @override
  void release(Object holder, int chunkX, int chunkZ) {}

  @override
  void releaseAll(Object holder) {}

  @override
  Uint8List? encoded(int chunkX, int chunkZ) {
    return packets.putIfAbsent((chunkX, chunkZ), () {
      encodes++;
      return encodeChunkColumn(
        chunkX: chunkX,
        chunkZ: chunkZ,
        primaryBitmask: payload.primaryBitmask,
        sections: payload.sections,
        biomes: payload.biomes,
        skylight: payload.skylight,
      );
    });
  }

  @override
  void addReadyListener(void Function(int chunkX, int chunkZ) listener) {}

  @override
  void removeReadyListener(void Function(int chunkX, int chunkZ) listener) {}
}
