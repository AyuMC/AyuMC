import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_world/ayu_world.dart';
import 'package:ayu_world/src/crc32.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const key = ChunkKey(worldId: ChunkKey.overworld, x: 4, z: -6);

  test('a varied column survives eviction, reload, and a clean restart', () async {
    final root = await Directory.systemTemp.createTemp('ayu-life-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final worldDir = Directory(p.join(root.path, 'overworld'));
    final firstGen = _VariedGenerator();
    final engine = await WorldEngine.open(
      worldDir: worldDir,
      generator: firstGen,
      encode: _encode,
      config: const ChunkConfig(cacheMiB: 0),
      seed: '7',
    );
    addTearDown(engine.close);
    engine.pipeline.addTicket(Object(), key, TicketReason.p0);
    await engine.pipeline.settle();
    final resident = engine.pipeline.record(key);
    expect(resident?.phase, ChunkPhase.resident);
    expect(firstGen.calls, 1);
    expect(resident!.dirty, isFalse);
    final saved = resident.payload!.pack();
    final unpacked = ChunkPayload.unpack(saved);
    expect(unpacked.primaryBitmask, 0x0003);
    expect(unpacked.presentSections, 2);
    expect(unpacked.biomes[0], isNot(1));
    expect(unpacked.sections[0], isNot(0));
    expect(engine.encoded(key.x, key.z), isNotNull);

    engine.pipeline.removeTicket(
      engine.pipeline.record(key)!.tickets.keys.single,
      key,
    );
    expect(engine.pipeline.record(key), isNull);
    expect(engine.pipeline.stats.evictions, greaterThan(0));

    engine.pipeline.addTicket(Object(), key, TicketReason.p0);
    await engine.pipeline.settle();
    expect(firstGen.calls, 1);
    expect(engine.pipeline.stats.storageHits, greaterThan(0));
    expect(engine.pipeline.record(key)!.payload!.pack(), orderedEquals(saved));
    engine.pipeline.tick();
    // ignore: avoid_print
    print('round-trip before restart ${engine.stats()}');
    await engine.close();

    final secondGen = _VariedGenerator();
    final restarted = await WorldEngine.open(
      worldDir: worldDir,
      generator: secondGen,
      encode: _encode,
      config: const ChunkConfig(cacheMiB: 0),
      seed: '7',
    );
    addTearDown(restarted.close);
    restarted.pipeline.addTicket(Object(), key, TicketReason.p0);
    await restarted.pipeline.settle();
    expect(secondGen.calls, 0);
    expect(
      restarted.pipeline.record(key)!.payload!.pack(),
      orderedEquals(saved),
    );
    restarted.pipeline.tick();
    // ignore: avoid_print
    print('round-trip snapshot ${restarted.stats()}');
  });

  test('an active ticket blocks eviction and a second holder keeps the column', () async {
    final pipeline = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 7,
      config: const ChunkConfig(cacheMiB: 0),
    );
    addTearDown(pipeline.close);
    final player = Object();
    final view = Object();
    final other = ChunkKey(worldId: key.worldId, x: key.x + 1, z: key.z);
    pipeline.addTicket(player, key, TicketReason.p0);
    pipeline.addTicket(view, key, TicketReason.p1);
    pipeline.addTicket(player, other, TicketReason.p1);
    pipeline.tick();
    expect(pipeline.record(key)?.phase, ChunkPhase.resident);
    expect(pipeline.record(other)?.phase, ChunkPhase.resident);
    expect(pipeline.stats.blockedEvictions, greaterThan(0));
    pipeline.removeTicket(player, key);
    expect(pipeline.record(key)?.phase, ChunkPhase.resident);
    expect(pipeline.record(key)!.tickets.containsKey(view), isTrue);
    pipeline.removeTicket(player, other);
    expect(pipeline.record(other), isNull);
    expect(pipeline.record(key), isNotNull);
    pipeline.removeTicket(view, key);
    expect(pipeline.record(key), isNull);
  });

  test('duplicate requests share one load and one resident payload', () async {
    final storage = _GateStorage();
    final generator = _VariedGenerator();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 7,
      storage: storage,
      config: const ChunkConfig(cacheMiB: 0),
    );
    addTearDown(pipeline.close);
    final first = Object();
    final second = Object();
    pipeline.addTicket(first, key, TicketReason.p0);
    pipeline.addTicket(second, key, TicketReason.p0);
    await storage.entered.future.timeout(const Duration(seconds: 2));
    expect(storage.lookups, 1);
    expect(pipeline.stats.dedupHits, greaterThan(0));
    expect(pipeline.residency.records, hasLength(1));
    storage.release.complete();
    await pipeline.settle();
    expect(generator.calls, 1);
    expect(pipeline.residency.records, hasLength(1));
    expect(pipeline.record(key)?.phase, ChunkPhase.resident);
    pipeline.releaseAll(first);
    expect(pipeline.record(key)!.tickets.containsKey(second), isTrue);
    expect(pipeline.record(key)!.tickets.containsKey(first), isFalse);
  });

  test('the queue stays inside its hard cap and drains after the load', () async {
    final generator = _VariedGenerator();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 1,
      config: const ChunkConfig(queuedSoft: 2, queuedHard: 2),
    );
    addTearDown(pipeline.close);
    final holder = Object();
    var maxQueued = 0;
    for (var i = 0; i < 5; i++) {
      pipeline.addTicket(
        holder,
        ChunkKey(worldId: key.worldId, x: i, z: 20),
        TicketReason.p1,
      );
      if (pipeline.scheduler.queuedCount > maxQueued) {
        maxQueued = pipeline.scheduler.queuedCount;
      }
    }
    expect(maxQueued, lessThanOrEqualTo(2));
    expect(
      pipeline.residency.records.values
          .where((record) => record.phase == ChunkPhase.wanted)
          .length,
      greaterThanOrEqualTo(3),
    );
    pipeline.tick();
    expect(
      pipeline.residency.records.values.where(
        (record) => record.phase == ChunkPhase.wanted,
      ),
      isNotEmpty,
    );
    await pipeline.settle();
    expect(pipeline.scheduler.queuedCount, 0);
    expect(
      pipeline.residency.records.values.every(
        (record) => record.phase == ChunkPhase.resident,
      ),
      isTrue,
    );
    expect(generator.calls, 5);
  });

  test('disk reads and per-player work stay at the configured caps', () async {
    final disk = _GateStorage();
    final diskPipeline = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 1,
      storage: disk,
      config: const ChunkConfig(diskReads: 1, perPlayerInFlight: 8),
    );
    addTearDown(diskPipeline.close);
    final holder = Object();
    for (var i = 0; i < 3; i++) {
      diskPipeline.addTicket(
        holder,
        ChunkKey(worldId: key.worldId, x: i, z: 30),
        TicketReason.p1,
      );
    }
    diskPipeline.tick();
    await disk.entered.future.timeout(const Duration(seconds: 2));
    expect(disk.lookups, 1);
    disk.release.complete();
    await diskPipeline.settle();
    expect(disk.lookups, 3);

    final player = _GateStorage();
    final playerPipeline = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 1,
      storage: player,
      config: const ChunkConfig(diskReads: 8, perPlayerInFlight: 1),
    );
    addTearDown(playerPipeline.close);
    for (var i = 0; i < 3; i++) {
      playerPipeline.addTicket(
        holder,
        ChunkKey(worldId: key.worldId, x: i, z: 31),
        TicketReason.p1,
      );
    }
    playerPipeline.tick();
    await player.entered.future.timeout(const Duration(seconds: 2));
    expect(player.lookups, 1);
    player.release.complete();
    await playerPipeline.settle();
    expect(player.lookups, 3);
    expect(
      playerPipeline.residency.records.values.every(
        (record) => record.phase == ChunkPhase.resident,
      ),
      isTrue,
    );
  });

  test('flushes do not overlap, and a failed store is retried', () async {
    final gated = _SlowStore();
    final pipeline = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 1,
      storage: gated,
      config: const ChunkConfig(diskFlushes: 1, groupCommitChunks: 100),
    );
    addTearDown(pipeline.close);
    addTearDown(() {
      if (!gated.release.isCompleted) gated.release.complete();
    });
    final holder = Object();
    final first = ChunkKey(worldId: key.worldId, x: 1, z: 40);
    final second = ChunkKey(worldId: key.worldId, x: 2, z: 40);
    final third = ChunkKey(worldId: key.worldId, x: 3, z: 40);
    pipeline.addTicket(holder, first, TicketReason.p0);
    pipeline.addTicket(holder, second, TicketReason.p0);
    await _untilPhase(pipeline, [first, second], ChunkPhase.resident);
    final flushing = pipeline.flushWrites();
    await gated.entered.future.timeout(const Duration(seconds: 2));
    pipeline.addTicket(holder, third, TicketReason.p0);
    await _untilPhase(pipeline, [third], ChunkPhase.resident);
    final next = pipeline.flushWrites();
    expect(gated.current, 1);
    expect(gated.stores, 1);
    gated.release.complete();
    await flushing;
    await next;
    expect(gated.maxConcurrent, 1);
    expect(await gated.inner.lookup(third), isA<ChunkLookup>());
    expect((await gated.inner.lookup(first)).kind, ChunkLookupKind.hit);
    expect((await gated.inner.lookup(third)).kind, ChunkLookupKind.hit);

    final root = await Directory.systemTemp.createTemp('ayu-life-disk-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final region = RegionLogStorage(root);
    await region.open();
    final failing = _FailingRegion(region);
    final durable = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 7,
      storage: failing,
      config: const ChunkConfig(groupCommitChunks: 100),
    );
    addTearDown(() async {
      failing.fail = false;
      await durable.close();
    });
    final kept = ChunkKey(worldId: key.worldId, x: 8, z: 8);
    final retry = ChunkKey(worldId: key.worldId, x: 9, z: 8);
    durable.addTicket(holder, kept, TicketReason.p0);
    durable.addTicket(holder, retry, TicketReason.p0);
    await _untilPhase(durable, [kept, retry], ChunkPhase.resident);
    await expectLater(durable.flushWrites(), throwsA(isA<StateError>()));
    final pair = [durable.record(kept)!, durable.record(retry)!];
    expect(pair.where((record) => record.dirty), hasLength(1));
    expect(durable.stats.storageFailures, greaterThan(0));
    final stored = pair.singleWhere((record) => !record.dirty);
    final missed = pair.singleWhere((record) => record.dirty);
    expect((await region.lookup(stored.key)).kind, ChunkLookupKind.hit);
    expect((await region.lookup(missed.key)).kind, ChunkLookupKind.miss);
    failing.fail = false;
    await durable.flushWrites();
    expect(durable.record(kept)!.dirty, isFalse);
    expect(durable.record(retry)!.dirty, isFalse);
    final keptBytes = durable.record(kept)!.payload!.pack();
    final retryBytes = durable.record(retry)!.payload!.pack();
    await durable.close();
    await durable.close();
    final reopened = RegionLogStorage(root);
    await reopened.open();
    addTearDown(reopened.close);
    expect((await reopened.lookup(kept)).payload!.pack(), orderedEquals(keptBytes));
    expect((await reopened.lookup(retry)).payload!.pack(), orderedEquals(retryBytes));
  });

  test('close waits for an in-flight read and can be called twice', () async {
    final storage = _GateStorage();
    final pipeline = ChunkPipeline(
      generator: _VariedGenerator(),
      seed: 1,
      storage: storage,
    );
    pipeline.addTicket(Object(), key, TicketReason.p0);
    await storage.entered.future.timeout(const Duration(seconds: 2));
    pipeline.releaseAll(pipeline.record(key)!.tickets.keys.single);
    final closing = pipeline.close();
    storage.release.complete();
    await closing.timeout(const Duration(seconds: 2));
    await pipeline.close();
    expect(pipeline.record(key), isNull);
  });

  test('a heavy generator runs on a worker, and close cancels queued jobs', () async {
    final local = _LocalBusy();
    final pool = await WorkerPool.start(size: 1, submitQueue: 8);
    final pipeline = ChunkPipeline(
      generator: local,
      seed: 1,
      workers: pool,
      config: const ChunkConfig(workers: 1, perPlayerInFlight: 4),
    );
    final holder = Object();
    for (var i = 0; i < 4; i++) {
      pipeline.addTicket(
        holder,
        ChunkKey(worldId: key.worldId, x: i, z: 50),
        TicketReason.p1,
      );
    }
    pipeline.tick();
    expect(local.calls, 0);
    expect(pipeline.stats.workerJobs, greaterThan(0));
    await pipeline.close().timeout(const Duration(seconds: 5));
    expect(local.calls, 0);
    expect(
      pipeline.stats.cancelled + pipeline.stats.generates,
      greaterThan(0),
    );
  });

  test('inline heavy work is visible to the loop-delay probe', () async {
    final pipeline = ChunkPipeline(
      generator: const BusyChunkGenerator(busyMicros: 160000),
      seed: 1,
    );
    addTearDown(pipeline.close);
    pipeline.probe.start();
    pipeline.addTicket(Object(), key, TicketReason.p1);
    pipeline.tick();
    final deadline = DateTime.now().add(const Duration(milliseconds: 400));
    while (pipeline.probe.ticks == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(pipeline.stats.generateMicros, greaterThanOrEqualTo(160000));
    expect(pipeline.probe.ticks, greaterThan(0));
    expect(pipeline.probe.lastLatenessMicros, greaterThan(0));
    // ignore: avoid_print
    print(
      'probe ticks=${pipeline.probe.ticks} '
      'latenessMicros=${pipeline.probe.lastLatenessMicros} '
      'generateMicros=${pipeline.stats.generateMicros} '
      'rss=${pipeline.stats.rss}',
    );
  });

  test('a failed generate is retried once and then dropped with its ticket', () async {
    final generator = _ThrowingGenerator();
    final pipeline = ChunkPipeline(generator: generator, seed: 1);
    addTearDown(pipeline.close);
    final holder = Object();
    pipeline.addTicket(holder, key, TicketReason.p0);
    await pipeline.settle();
    expect(generator.calls, 2);
    expect(pipeline.record(key)?.phase, ChunkPhase.failed);
    expect(pipeline.stats.retries, greaterThan(0));
    pipeline.removeTicket(holder, key);
    expect(pipeline.record(key), isNull);
  });

  test('player-modified corruption is not regenerated', () async {
    final root = await Directory.systemTemp.createTemp('ayu-life-mod-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final region = RegionLogStorage(root);
    await region.open();
    final payload = _variedPayload(key.x, key.z, salt: 5);
    await region.store(
      key,
      payload,
      generatorId: 'varied',
      generatorVersion: 1,
      regenerable: false,
      playerModified: true,
      finalized: true,
    );
    await region.close();
    final file = File(
      p.join(
        root.path,
        'region',
        'r.${regionCoord(key.x)}.${regionCoord(key.z)}.1.ayur',
      ),
    );
    final bytes = await file.readAsBytes();
    final frame = _lastFrame(bytes);
    final length = _le(bytes, frame);
    final body = Uint8List.sublistView(bytes, frame + 8, frame + 8 + length);
    body[body.length - payload.pack().length] = 9;
    final crc = Crc32.compute(body);
    bytes[frame + 4] = crc & 0xFF;
    bytes[frame + 5] = (crc >> 8) & 0xFF;
    bytes[frame + 6] = (crc >> 16) & 0xFF;
    bytes[frame + 7] = (crc >> 24) & 0xFF;
    await file.writeAsBytes(bytes, flush: true);

    final generator = _VariedGenerator();
    final reopened = RegionLogStorage(root);
    await reopened.open();
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: 7,
      storage: reopened,
    );
    addTearDown(pipeline.close);
    pipeline.addTicket(Object(), key, TicketReason.p0);
    await pipeline.settle();
    expect(generator.calls, 0);
    expect(pipeline.record(key)?.phase, ChunkPhase.failed);
    expect(
      File(p.join(root.path, 'quarantine', 'c.${key.x}.${key.z}.bin')).existsSync(),
      isTrue,
    );
  });

  test('a stale generation result does not replace the resident payload', () async {
    final pipeline = ChunkPipeline(generator: _VariedGenerator(), seed: 7);
    addTearDown(pipeline.close);
    pipeline.addTicket(Object(), key, TicketReason.p0);
    final saved = pipeline.record(key)!.payload!.pack();
    pipeline.debugDeliver(
      key: key,
      epoch: 1,
      payload: const FlatStonePadGenerator().generate(seed: 0, x: 0, z: 0),
    );
    expect(pipeline.stats.staleResults, greaterThan(0));
    expect(pipeline.record(key)!.payload!.pack(), orderedEquals(saved));
  });
}

Uint8List _encode(int x, int z, ChunkPayload payload) =>
    Uint8List.fromList([x & 0xFF, z & 0xFF, ...payload.pack()]);

Future<void> _untilPhase(
  ChunkPipeline pipeline,
  List<ChunkKey> keys,
  ChunkPhase phase,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (keys.any((key) => pipeline.record(key)?.phase != phase)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$keys did not reach $phase');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

ChunkPayload _variedPayload(int x, int z, {required int salt}) {
  final sectionBytes = ChunkPayload.sectionBytes(true);
  final sections = Uint8List(sectionBytes * 2);
  for (var i = 0; i < 4096; i++) {
    final value = (salt * 1009 + x * 131 + z * 17 + i) & 0xFFFF;
    sections[i * 2] = value & 0xFF;
    sections[i * 2 + 1] = (value >> 8) & 0xFF;
  }
  for (var i = 0; i < 2048; i++) {
    sections[8192 + i] = (x + i + salt) & 0xFF;
  }
  final biomes = Uint8List(ChunkPayload.biomeBytes);
  for (var i = 0; i < biomes.length; i++) {
    biomes[i] = (x + z + i + salt) & 0xFF;
  }
  return ChunkPayload(
    primaryBitmask: 0x0003,
    skylight: true,
    biomes: biomes,
    sections: sections,
  );
}

int _lastFrame(Uint8List bytes) {
  var offset = 8;
  var last = 8;
  while (offset + 8 <= bytes.length) {
    final length = _le(bytes, offset);
    if (length <= 0 || offset + 8 + length > bytes.length) break;
    last = offset;
    offset += 8 + length;
  }
  return last;
}

int _le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

final class _VariedGenerator implements ChunkGenerator {
  int calls = 0;

  @override
  String get id => 'varied';

  @override
  int get version => 1;

  @override
  bool get heavy => false;

  @override
  bool get requiresNeighbors => false;

  @override
  SpawnPoint get spawn => FlatStonePadGenerator.padSpawn;

  @override
  ChunkPayload generate({required int seed, required int x, required int z}) {
    calls++;
    return _variedPayload(x, z, salt: seed);
  }
}

final class _ThrowingGenerator implements ChunkGenerator {
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
    throw StateError('generation failed');
  }
}

final class _LocalBusy implements ChunkGenerator {
  int calls = 0;
  final ChunkGenerator _inner = const BusyChunkGenerator();

  @override
  String get id => _inner.id;

  @override
  int get version => _inner.version;

  @override
  bool get heavy => true;

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

final class _GateStorage implements ChunkStorage {
  final MemoryChunkStorage inner = MemoryChunkStorage();
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int lookups = 0;

  @override
  Future<ChunkLookup> lookup(ChunkKey key) async {
    lookups++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return inner.lookup(key);
  }

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) {
    return inner.store(
      key,
      payload,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: regenerable,
      playerModified: playerModified,
      finalized: finalized,
    );
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) =>
      inner.quarantine(key, bytes);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}

final class _SlowStore implements ChunkStorage {
  final MemoryChunkStorage inner = MemoryChunkStorage();
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int stores = 0;
  int current = 0;
  int maxConcurrent = 0;

  @override
  Future<ChunkLookup> lookup(ChunkKey key) => inner.lookup(key);

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) async {
    stores++;
    current++;
    if (current > maxConcurrent) maxConcurrent = current;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    current--;
    await inner.store(
      key,
      payload,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: regenerable,
      playerModified: playerModified,
      finalized: finalized,
    );
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) =>
      inner.quarantine(key, bytes);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}

final class _FailingRegion implements ChunkStorage {
  _FailingRegion(this.inner);

  final RegionLogStorage inner;
  var fail = true;
  int stores = 0;

  @override
  Future<ChunkLookup> lookup(ChunkKey key) => inner.lookup(key);

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) async {
    stores++;
    if (fail && stores >= 2) throw StateError('disk');
    await inner.store(
      key,
      payload,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: regenerable,
      playerModified: playerModified,
      finalized: finalized,
    );
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) =>
      inner.quarantine(key, bytes);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}
