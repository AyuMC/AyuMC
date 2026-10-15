import 'dart:typed_data';

import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  const key = ChunkKey(worldId: ChunkKey.overworld, x: 2, z: -3);

  test('many tickets share one generate', () async {
    final generator = _CountingGenerator();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 1,
      encoder: (x, z, payload) => Uint8List.fromList([x & 0xFF, z & 0xFF]),
    );
    addTearDown(pipeline.close);
    final a = Object();
    final b = Object();
    pipeline.addTicket(a, key, TicketReason.p0);
    pipeline.addTicket(b, key, TicketReason.p0);
    expect(generator.calls, 1);
    expect(pipeline.record(key)?.phase, ChunkPhase.resident);
    expect(pipeline.stats.dedupHits, greaterThan(0));
    final first = pipeline.encoded(key);
    final second = pipeline.encoded(key);
    expect(identical(first, second), isTrue);
    expect(pipeline.stats.encodes, 1);
  });

  test('a stale epoch result is discarded', () async {
    final pipeline = ChunkPipeline(
      generator: const FlatStonePadGenerator(),
      seed: 0,
    );
    addTearDown(pipeline.close);
    final holder = Object();
    pipeline.addTicket(holder, key, TicketReason.p1);
    expect(pipeline.record(key)?.phase, ChunkPhase.queued);
    pipeline.debugDeliver(
      key: key,
      epoch: 99,
      payload: const FlatStonePadGenerator().generate(seed: 0, x: 2, z: -3),
    );
    expect(pipeline.stats.staleResults, 1);
    expect(pipeline.record(key)?.phase, ChunkPhase.queued);
  });

  test('cancelling the last ticket before start does no work', () async {
    final generator = _CountingGenerator();
    final pipeline = ChunkPipeline(generator: generator, seed: 0);
    addTearDown(pipeline.close);
    final holder = Object();
    pipeline.addTicket(holder, key, TicketReason.p1);
    pipeline.removeTicket(holder, key);
    await pipeline.pump();
    expect(generator.calls, 0);
    expect(pipeline.record(key), isNull);
  });

  test('completion without tickets obeys the water line', () async {
    final generator = _CountingGenerator();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 0,
      config: const ChunkConfig(cacheMiB: 0),
    );
    addTearDown(pipeline.close);
    final holder = Object();
    pipeline.addTicket(holder, key, TicketReason.p1);
    final record = pipeline.record(key)!;
    record.phase = ChunkPhase.generating;
    record.jobEpoch = 7;
    pipeline.removeTicket(holder, key);
    expect(pipeline.record(key)?.referenced, isFalse);
    pipeline.debugDeliver(
      key: key,
      epoch: 7,
      payload: const FlatStonePadGenerator().generate(seed: 0, x: 2, z: -3),
    );
    expect(pipeline.record(key), isNull);
  });

  test('a storage hit is not generated again', () async {
    final storage = MemoryChunkStorage();
    final payload = const FlatStonePadGenerator().generate(seed: 0, x: 2, z: -3);
    await storage.store(
      key,
      payload,
      generatorId: FlatStonePadGenerator.idName,
      generatorVersion: 1,
      regenerable: true,
      playerModified: false,
      finalized: true,
    );
    final generator = _CountingGenerator();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 0,
      storage: storage,
    );
    addTearDown(pipeline.close);
    pipeline.addTicket(Object(), key, TicketReason.p0);
    await pipeline.pump();
    expect(pipeline.record(key)?.phase, ChunkPhase.resident);
    expect(generator.calls, 0);
    expect(pipeline.stats.storageHits, 1);
  });
}

final class _CountingGenerator implements ChunkGenerator {
  int calls = 0;
  final ChunkGenerator _inner = const FlatStonePadGenerator();

  @override
  String get id => _inner.id;

  @override
  int get version => _inner.version;

  @override
  bool get heavy => false;

  @override
  bool get requiresNeighbors => false;

  @override
  SpawnPoint get spawn => _inner.spawn;

  @override
  ChunkPayload generate({required int seed, required int x, required int z}) {
    calls++;
    return _inner.generate(seed: seed, x: x, z: z);
  }
}
