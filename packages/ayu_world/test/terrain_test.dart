import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_world/ayu_world.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const seed = 42;

  test('the same seed and coordinates produce the same column', () {
    final a = TerrainGeneratorV1();
    final b = TerrainGeneratorV1();
    expect(
      a.generate(seed: seed, x: 3, z: -5).pack(),
      orderedEquals(b.generate(seed: seed, x: 3, z: -5).pack()),
    );
    expect(
      a.generate(seed: seed, x: 3, z: -5).pack(),
      isNot(orderedEquals(a.generate(seed: seed + 1, x: 3, z: -5).pack())),
    );
  });

  test(
    'adjacent chunks share an edge and negative coordinates stay continuous',
    () {
      final generator = TerrainGeneratorV1();
      final origin = generator.generate(seed: seed, x: 0, z: 0);
      final east = generator.generate(seed: seed, x: 1, z: 0);
      final west = generator.generate(seed: seed, x: -1, z: 0);
      for (var lz = 0; lz < 16; lz++) {
        expect(_surfaceY(origin, 15, lz), generator.heightAt(seed, 15, lz));
        expect(_surfaceY(east, 0, lz), generator.heightAt(seed, 16, lz));
        expect(_surfaceY(west, 15, lz), generator.heightAt(seed, -1, lz));
        expect(
          (generator.heightAt(seed, 15, lz) - generator.heightAt(seed, 16, lz))
              .abs(),
          lessThan(8),
        );
        expect(
          (generator.heightAt(seed, -1, lz) - generator.heightAt(seed, 0, lz))
              .abs(),
          lessThan(8),
        );
      }
      expect(origin.pack(), isNot(orderedEquals(east.pack())));
    },
  );

  test('heights, sections, biomes, and column sky light stay in range', () {
    final generator = TerrainGeneratorV1();
    final payload = generator.generate(seed: seed, x: 2, z: -3);
    expect(payload.skylight, isTrue);
    expect(payload.biomes.length, 256);
    expect(payload.presentSections, inInclusiveRange(1, 16));
    expect(payload.primaryBitmask, (1 << payload.presentSections) - 1);
    expect(
      payload.sections.length,
      payload.presentSections * ChunkPayload.sectionBytes(true),
    );
    var sawGrass = false;
    var sawAirSky = false;
    var sawDarkStone = false;
    for (var lz = 0; lz < 16; lz++) {
      for (var lx = 0; lx < 16; lx++) {
        final biome = payload.biomes[(lz << 4) | lx];
        expect(
          biome,
          anyOf(
            TerrainGeneratorV1.biomeOcean,
            TerrainGeneratorV1.biomePlains,
            TerrainGeneratorV1.biomeBeach,
          ),
        );
        expect(readBlockId(payload, lx, 0, lz), TerrainGeneratorV1.bedrock);
        var surface = 0;
        for (var y = 1; y <= 255; y++) {
          if (readBlockId(payload, lx, y, lz) != 0) surface = y;
        }
        expect(surface, lessThanOrEqualTo(TerrainGeneratorV1.maxHeight));
        expect(surface, greaterThanOrEqualTo(1));
        final top = readBlockId(payload, lx, surface, lz);
        if (top == TerrainGeneratorV1.grass) {
          sawGrass = true;
          expect(readBlockId(payload, lx, surface + 1, lz), 0);
          expect(readSkyLightNibble(payload, lx, surface + 1, lz), 15);
          expect(readSkyLightNibble(payload, lx, surface, lz), 0);
          if (surface > 4) {
            expect(readSkyLightNibble(payload, lx, 1, lz), 0);
            sawDarkStone = true;
          }
        }
        if (readSkyLightNibble(payload, lx, surface + 1, lz) == 15) {
          sawAirSky = true;
        }
      }
    }
    expect(sawGrass || sawAirSky, isTrue);
    expect(sawDarkStone || sawAirSky, isTrue);
  });

  test('safe spawn stands on grass or sand with air at the feet', () async {
    final pipeline = ChunkPipeline(
      generator: TerrainGeneratorV1(),
      seed: seed,
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
    final lx = found.spawn.blockX - found.chunkX * 16;
    final lz = found.spawn.blockZ - found.chunkZ * 16;
    final ground = readBlockId(payload, lx, found.spawn.blockY, lz);
    expect(ground, anyOf(TerrainGeneratorV1.grass, TerrainGeneratorV1.sand));
    expect(readBlockId(payload, lx, found.spawn.blockY + 1, lz), 0);
    expect(readBlockId(payload, lx, found.spawn.blockY + 2, lz), 0);
    expect(
      readBlockId(payload, lx, found.spawn.blockY + 1, lz),
      isNot(TerrainGeneratorV1.water),
    );
    expect(
      [
        TerrainGeneratorV1.stone,
        TerrainGeneratorV1.dirt,
        TerrainGeneratorV1.grass,
        TerrainGeneratorV1.sand,
        TerrainGeneratorV1.water,
        TerrainGeneratorV1.bedrock,
      ].contains(readBlockId(payload, lx, found.spawn.feetY.floor(), lz)),
      isFalse,
    );
    expect(const FlatStonePadGenerator().spawn.feetY, 16.0);
    expect(const FlatStonePadGenerator().spawn.levelType, 'flat');
  });

  test(
    'canonical columns keep bedrock, solid fill, and the intended surface',
    () {
      final generator = TerrainGeneratorV1();
      const chunks = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1)];
      var sawGrass = false;
      var sawSand = false;
      var sawWater = false;
      var sawHighland = false;
      for (final cell in chunks) {
        final payload = generator.generate(seed: seed, x: cell.$1, z: cell.$2);
        expect(payload.presentSections, greaterThanOrEqualTo(2));
        expect(payload.primaryBitmask, (1 << payload.presentSections) - 1);
        expect(
          payload.sections.length,
          payload.presentSections * ChunkPayload.sectionBytes(true),
        );
        for (var lz = 0; lz < 16; lz++) {
          for (var lx = 0; lx < 16; lx++) {
            final h = generator.heightAt(
              seed,
              cell.$1 * 16 + lx,
              cell.$2 * 16 + lz,
            );
            expect(readBlockId(payload, lx, 0, lz), TerrainGeneratorV1.bedrock);
            final sandy = h <= TerrainGeneratorV1.seaLevel + 2;
            for (var y = 1; y < h; y++) {
              final id = readBlockId(payload, lx, y, lz);
              final expected = y >= h - 2
                  ? (sandy ? TerrainGeneratorV1.sand : TerrainGeneratorV1.dirt)
                  : TerrainGeneratorV1.stone;
              expect(
                id,
                expected,
                reason: 'fill at ($lx,$y,$lz) chunk ${cell.$1},${cell.$2}',
              );
            }
            final surface = readBlockId(payload, lx, h, lz);
            expect(
              surface,
              sandy ? TerrainGeneratorV1.sand : TerrainGeneratorV1.grass,
            );
            if (surface == TerrainGeneratorV1.grass) sawGrass = true;
            if (surface == TerrainGeneratorV1.sand) sawSand = true;
            if (h < TerrainGeneratorV1.seaLevel) {
              sawWater = true;
              for (var y = h + 1; y <= TerrainGeneratorV1.seaLevel; y++) {
                expect(
                  readBlockId(payload, lx, y, lz),
                  TerrainGeneratorV1.water,
                );
              }
              expect(
                readBlockId(payload, lx, TerrainGeneratorV1.seaLevel + 1, lz),
                0,
              );
            } else {
              if (h > TerrainGeneratorV1.seaLevel + 2) sawHighland = true;
              expect(readBlockId(payload, lx, h + 1, lz), 0);
            }
            final top = h < TerrainGeneratorV1.seaLevel
                ? TerrainGeneratorV1.seaLevel
                : h;
            for (var y = top + 1; y <= 132; y++) {
              expect(readBlockId(payload, lx, y, lz), 0);
            }
          }
        }
      }
      expect(sawSand, isTrue);
      for (var cz = -8; cz <= 8; cz++) {
        for (var cx = -8; cx <= 8; cx++) {
          final h = generator.heightAt(seed, cx * 16 + 8, cz * 16 + 8);
          if (h < TerrainGeneratorV1.seaLevel) sawWater = true;
          if (h > TerrainGeneratorV1.seaLevel + 2) sawHighland = true;
          if (h > TerrainGeneratorV1.seaLevel &&
              h <= TerrainGeneratorV1.seaLevel + 2) {
            sawSand = true;
          }
          if (h > TerrainGeneratorV1.seaLevel + 2) sawGrass = true;
        }
      }
      expect(sawWater, isTrue);
      expect(sawHighland, isTrue);
      expect(sawGrass, isTrue);
    },
  );

  test('spawn prefers dry grass over dry sand in an earlier chunk', () async {
    final pipeline = ChunkPipeline(
      generator: const _SandThenGrassGenerator(),
      seed: seed,
      config: const ChunkConfig(workers: 0),
    );
    addTearDown(pipeline.close);
    final found = await findSafeSpawn(pipeline);
    expect(found.fallback, isFalse);
    expect(found.chunkX, 1);
    expect(found.chunkZ, 0);
    expect(found.spawn.blockY, 30);
    expect(found.spawn.feetY, 31.0);
  });

  test('spawn rejects submerged sand and obstructed grass', () async {
    final wet = ChunkPipeline(
      generator: const _SubmergedSandGenerator(),
      seed: seed,
      config: const ChunkConfig(workers: 0),
    );
    addTearDown(wet.close);
    final wetFound = await findSafeSpawn(wet, maxChunks: 4);
    expect(wetFound.fallback, isTrue);
    expect(wetFound.spawn.blockY, TerrainGeneratorV1.seaLevel);

    final blocked = ChunkPipeline(
      generator: const _ObstructedGrassGenerator(),
      seed: seed,
      config: const ChunkConfig(workers: 0),
    );
    addTearDown(blocked.close);
    final drySand = await findSafeSpawn(blocked);
    expect(drySand.fallback, isFalse);
    expect(drySand.chunkX, 0);
    expect(drySand.chunkZ, 0);
    expect(drySand.spawn.blockY, 11);
  });

  test('worker count and job order do not change packed bytes', () async {
    const keys = [
      ChunkKey(worldId: ChunkKey.overworld, x: 0, z: 0),
      ChunkKey(worldId: ChunkKey.overworld, x: 1, z: -1),
    ];
    final inline = await _packed(0, keys);
    final one = await _packed(1, keys);
    final two = await _packed(2, keys.reversed.toList());
    expect(one, inline);
    expect(two, inline);
  });

  test('a terrain column survives region-log eviction and reopen', () async {
    final root = await Directory.systemTemp.createTemp('ayu-terrain-life-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const key = ChunkKey(worldId: ChunkKey.overworld, x: 4, z: -2);
    final worldDir = Directory(p.join(root.path, 'overworld'));
    final first = await WorldEngine.open(
      worldDir: worldDir,
      generator: TerrainGeneratorV1(),
      encode: _encode,
      seed: '$seed',
      config: const ChunkConfig(workers: 0, cacheMiB: 0),
    );
    addTearDown(first.close);
    first.pipeline.addTicket(Object(), key, TicketReason.p0);
    await first.pipeline.settle();
    final saved = first.pipeline.record(key)!.payload!.pack();
    first.pipeline.releaseAll(first.pipeline.record(key)!.tickets.keys.single);
    expect(first.pipeline.record(key), isNull);
    await first.close();

    final second = await WorldEngine.open(
      worldDir: worldDir,
      generator: TerrainGeneratorV1(),
      encode: _encode,
      seed: '999',
      config: const ChunkConfig(workers: 0, cacheMiB: 0),
    );
    addTearDown(second.close);
    expect(second.profile.seed, '$seed');
    expect(second.profile.generatorId, TerrainGeneratorV1.idName);
    second.pipeline.addTicket(Object(), key, TicketReason.p0);
    await second.pipeline.settle();
    expect(second.pipeline.stats.storageHits, greaterThan(0));
    expect(second.pipeline.record(key)!.payload!.pack(), orderedEquals(saved));
    expect(second.pipeline.stats.generates, 0);
  });

  test('an existing stone-pad world is not switched to terrain', () async {
    final root = await Directory.systemTemp.createTemp('ayu-pad-world-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    await File(p.join(root.path, 'world.json')).writeAsString(
      '{"worldId":"overworld","seed":"7","generatorId":"flat_stone_pad",'
      '"generatorVersion":1,"storage":"ayur"}\n',
    );
    expect(WorldProfile.generatorFor(root).id, FlatStonePadGenerator.idName);
    expect(WorldProfile.seedFor(root, configured: '99'), '7');
    await File(p.join(root.path, 'world.json')).writeAsString(
      '{"worldId":"overworld","seed":"1","generatorId":"no_such_gen",'
      '"generatorVersion":1,"storage":"ayur"}\n',
    );
    expect(
      () => WorldProfile.generatorFor(root),
      throwsA(isA<UnknownGeneratorException>()),
    );
    expect(
      File(p.join(root.path, 'world.json')).readAsStringSync(),
      contains('no_such_gen'),
    );
  });

  test(
    'two tickets share one worker generation and close does not stick',
    () async {
      final pool = await WorkerPool.start(size: 1, submitQueue: 4);
      final generator = TerrainGeneratorV1();
      final pipeline = ChunkPipeline(
        generator: generator,
        seed: seed,
        workers: pool,
        config: const ChunkConfig(workers: 1),
      );
      const key = ChunkKey(worldId: ChunkKey.overworld, x: 0, z: 0);
      final a = Object();
      final b = Object();
      pipeline.addTicket(a, key, TicketReason.p0);
      pipeline.addTicket(b, key, TicketReason.p0);
      await pipeline.settle();
      expect(pipeline.stats.generates, 1);
      expect(pipeline.stats.dedupHits, greaterThan(0));
      expect(pipeline.residency.records, hasLength(1));
      await pipeline.close();
      expect(pipeline.record(key)?.phase, isNot(ChunkPhase.generating));
    },
  );

  test('priority-0 work stays ahead of background pre-generation', () async {
    final pipeline = ChunkPipeline(
      generator: TerrainGeneratorV1(),
      seed: seed,
      config: const ChunkConfig(workers: 0, inlineBudget: Duration.zero),
    );
    addTearDown(pipeline.close);
    final pregen = Object();
    pipeline.addPregenHolder(pregen);
    for (var i = 0; i < 8; i++) {
      pipeline.addTicket(
        pregen,
        ChunkKey(worldId: ChunkKey.overworld, x: i + 10, z: 40),
        TicketReason.p4,
      );
    }
    const spawn = ChunkKey(worldId: ChunkKey.overworld, x: 0, z: 0);
    pipeline.addTicket(Object(), spawn, TicketReason.p0);
    pipeline.tick();
    expect(pipeline.record(spawn)?.phase, ChunkPhase.resident);
    expect(
      pipeline.residency.records.values.any(
        (record) =>
            record.highestReason == TicketReason.p4 &&
            record.phase != ChunkPhase.resident,
      ),
      isTrue,
    );
  });

  test(
    'automatic workers start for terrain and stay off for the stone pad',
    () {
      final terrain = resolveWorkerPlan(
        requested: -1,
        heavy: true,
        processors: 8,
        maxWorkers: 8,
      );
      expect(terrain.mode, WorkerMode.automatic);
      expect(terrain.count, 7);
      final pad = resolveWorkerPlan(requested: -1, heavy: false, processors: 8);
      expect(pad.count, 0);
      final inline = resolveWorkerPlan(
        requested: 0,
        heavy: true,
        processors: 8,
      );
      expect(inline.mode, WorkerMode.inline);
      expect(inline.count, 0);
      final clamped = resolveWorkerPlan(
        requested: 32,
        heavy: true,
        maxWorkers: 8,
        processors: 16,
      );
      expect(clamped.count, 8);
      expect(ChunkRuntimeConfig.fromServerJson({}).workers, -1);
      expect(
        ChunkRuntimeConfig.fromServerJson({
          'chunks': {'workers': 0},
        }).workers,
        0,
      );
    },
  );
}

int _surfaceY(ChunkPayload payload, int lx, int lz) {
  for (var y = 255; y >= 0; y--) {
    final id = readBlockId(payload, lx, y, lz);
    if (id != 0 && id != TerrainGeneratorV1.water) return y;
  }
  return 0;
}

void _putGrouped(Uint8List sections, int bitmask, int x, int y, int z, int id) {
  final size = ChunkPayload.sectionBytes(true);
  final section = y >> 4;
  var present = 0;
  for (var s = 0; s < section; s++) {
    if (bitmask & (1 << s) != 0) present++;
  }
  final index = present * size + (((y & 15) << 8) | (z << 4) | x) * 2;
  final value = id << 4;
  sections[index] = value & 0xFF;
  sections[index + 1] = (value >> 8) & 0xFF;
}

ChunkPayload _stackColumn({
  required int bitmask,
  required int surfaceY,
  required int surfaceId,
  int waterTo = -1,
  void Function(Uint8List sections, int lx, int lz)? extra,
}) {
  final present = ChunkPayload.countSections(bitmask);
  final sections = Uint8List(present * ChunkPayload.sectionBytes(true));
  final biomes = Uint8List(256)..fillRange(0, 256, 1);
  for (var lz = 0; lz < 16; lz++) {
    for (var lx = 0; lx < 16; lx++) {
      _putGrouped(sections, bitmask, lx, 0, lz, TerrainGeneratorV1.bedrock);
      for (var y = 1; y < surfaceY; y++) {
        _putGrouped(sections, bitmask, lx, y, lz, TerrainGeneratorV1.stone);
      }
      _putGrouped(sections, bitmask, lx, surfaceY, lz, surfaceId);
      if (waterTo >= 0) {
        for (var y = surfaceY + 1; y <= waterTo; y++) {
          _putGrouped(sections, bitmask, lx, y, lz, TerrainGeneratorV1.water);
        }
      }
      extra?.call(sections, lx, lz);
    }
  }
  return ChunkPayload(
    primaryBitmask: bitmask,
    skylight: true,
    biomes: biomes,
    sections: sections,
  );
}

final class _SandThenGrassGenerator implements ChunkGenerator {
  const _SandThenGrassGenerator();

  @override
  String get id => 'test_sand_then_grass';

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
    const bitmask = 0x0007;
    if (x == 0 && z == 0) {
      return _stackColumn(
        bitmask: bitmask,
        surfaceY: 20,
        surfaceId: TerrainGeneratorV1.sand,
      );
    }
    if (x == 1 && z == 0) {
      return _stackColumn(
        bitmask: bitmask,
        surfaceY: 30,
        surfaceId: TerrainGeneratorV1.grass,
      );
    }
    return _stackColumn(
      bitmask: bitmask,
      surfaceY: 10,
      surfaceId: TerrainGeneratorV1.stone,
    );
  }
}

final class _SubmergedSandGenerator implements ChunkGenerator {
  const _SubmergedSandGenerator();

  @override
  String get id => 'test_submerged_sand';

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
    return _stackColumn(
      bitmask: 0x001F,
      surfaceY: 40,
      surfaceId: TerrainGeneratorV1.sand,
      waterTo: TerrainGeneratorV1.seaLevel,
    );
  }
}

final class _ObstructedGrassGenerator implements ChunkGenerator {
  const _ObstructedGrassGenerator();

  @override
  String get id => 'test_obstructed_grass';

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
    const bitmask = 0x0007;
    return _stackColumn(
      bitmask: bitmask,
      surfaceY: 11,
      surfaceId: TerrainGeneratorV1.sand,
      extra: (sections, lx, lz) {
        _putGrouped(sections, bitmask, lx, 39, lz, TerrainGeneratorV1.stone);
        _putGrouped(sections, bitmask, lx, 40, lz, TerrainGeneratorV1.grass);
        _putGrouped(sections, bitmask, lx, 42, lz, TerrainGeneratorV1.stone);
      },
    );
  }
}

Uint8List _encode(int x, int z, ChunkPayload payload) =>
    Uint8List.fromList([x & 0xFF, z & 0xFF, ...payload.pack()]);

Future<Map<ChunkKey, List<int>>> _packed(
  int workers,
  List<ChunkKey> keys,
) async {
  WorkerPool? pool;
  if (workers > 0) {
    pool = await WorkerPool.start(size: workers, submitQueue: 8);
  }
  final pipeline = ChunkPipeline(
    generator: TerrainGeneratorV1(),
    seed: 42,
    workers: pool,
    encoder: _encode,
    config: ChunkConfig(workers: workers),
  );
  final holder = Object();
  for (final key in keys) {
    pipeline.addTicket(holder, key, TicketReason.p0);
  }
  await pipeline.settle();
  final out = <ChunkKey, List<int>>{
    for (final key in keys) key: pipeline.record(key)!.payload!.pack(),
  };
  await pipeline.close();
  return out;
}
