import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'budgets.dart';
import 'demand.dart';
import 'generator.dart';
import 'key.dart';
import 'memory_storage.dart';
import 'pipeline.dart';
import 'pregen.dart';
import 'region_log.dart';
import 'spawn.dart';
import 'storage.dart';
import 'terrain.dart';
import 'tuning.dart';
import 'worker_pool.dart';
import 'world_profile.dart';

final class WorldEngine {
  WorldEngine({
    required this.profile,
    required this.pipeline,
    required this.demand,
    required this.pregen,
    required this.storage,
    required this.generator,
    required this.config,
    required this.spawn,
    required this.workerPlan,
    this.spawnFallback = false,
  });

  final WorldProfile profile;
  final ChunkPipeline pipeline;
  final ChunkDemand demand;
  final PregenService pregen;
  final ChunkStorage storage;
  final ChunkGenerator generator;
  final ChunkConfig config;
  final SpawnPoint spawn;
  WorkerPlan workerPlan;
  final bool spawnFallback;

  static Future<WorldEngine> open({
    required Directory worldDir,
    required ChunkGenerator generator,
    required ChunkPacketEncoder encode,
    ChunkConfig config = const ChunkConfig(),
    String storageId = 'ayur',
    String seed = '0',
  }) async {
    final profile = await WorldProfile.loadOrCreate(
      worldDir,
      generator,
      storage: storageId,
      seed: seed,
    );
    late final ChunkStorage storage;
    if (profile.storage == 'memory') {
      storage = MemoryChunkStorage();
    } else {
      final region = RegionLogStorage(worldDir, worldId: profile.worldId);
      await region.open();
      storage = region;
    }
    final plan = resolveWorkerPlan(
      requested: config.workers,
      heavy: generator.heavy,
      maxWorkers: config.maxWorkers,
    );
    WorkerPool? pool;
    if (plan.count > 0) {
      pool = await WorkerPool.start(
        size: plan.count,
        transferableBytes: config.transferableBytes,
        submitQueue: config.workerSubmitQueue,
      );
    }
    final pipeline = ChunkPipeline(
      generator: generator,
      seed: profile.seedValue,
      storage: storage,
      encoder: encode,
      workers: pool,
      config: config,
    );
    pipeline.probe.start();
    final demand = ChunkDemand(pipeline, worldId: profile.worldId);
    final pregen = PregenService(
      directory: Directory(p.join(worldDir.path, 'pregen')),
      pipeline: pipeline,
      demand: demand,
      storage: storage,
      generatorId: generator.id,
      generatorVersion: generator.version,
      workingSet: config.pregenTickets,
    );
    await pregen.load();
    pipeline.addReadyListener(pregen.onResident);
    var spawn = generator.spawn;
    var spawnFallback = false;
    if (generator.id == TerrainGeneratorV1.idName) {
      final found = await findSafeSpawn(
        pipeline,
        worldId: profile.worldId,
      );
      spawn = found.spawn;
      spawnFallback = found.fallback;
    }
    return WorldEngine(
      profile: profile,
      pipeline: pipeline,
      demand: demand,
      pregen: pregen,
      storage: storage,
      generator: generator,
      config: config,
      spawn: spawn,
      workerPlan: plan,
      spawnFallback: spawnFallback,
    );
  }

  Uint8List? encoded(int chunkX, int chunkZ) => pipeline.encoded(
        ChunkKey(worldId: profile.worldId, x: chunkX, z: chunkZ),
      );

  void tick() {
    pipeline.tick();
    unawaited(pregen.pump().then((_) => pipeline.tick()));
  }

  Future<void> pump() async {
    await pregen.pump();
    await pipeline.pump();
  }

  Future<void> close() async {
    await pregen.close();
    await pipeline.close();
  }

  Map<String, Object?> stats() => pipeline.stats.snapshot();

  /// Live-adjustable pipeline limits. The engine's configuration service reads
  /// and writes these; the manager never touches them directly.
  ChunkTuning get tuning => pipeline.tuning;

  /// Applies one live tuning value. Returns null when the key is unknown;
  /// otherwise the previous value, so a caller can roll back.
  int? applyTuning(String key, int value) => pipeline.tuning.setFrom(key, value);

  /// Applies a worker pool size computed from the generator and the new
  /// configuration. Never cancels in-flight generation.
  Future<WorkerPlan> applyWorkerPlan(
    WorkerPlan plan, {
    int transferableBytes = 32768,
    int submitQueue = 256,
  }) async {
    final applied = await pipeline.reconfigureWorkers(
      plan,
      transferableBytes: transferableBytes,
      submitQueue: submitQueue,
    );
    workerPlan = applied;
    return applied;
  }

  /// Resolves and applies a new `chunks.workers` request.
  Future<WorkerPlan> resolveAndApplyWorkers({
    required int requested,
    required int maxWorkers,
    int transferableBytes = 32768,
    int submitQueue = 256,
  }) {
    final plan = resolveWorkerPlan(
      requested: requested,
      heavy: generator.heavy,
      maxWorkers: maxWorkers,
    );
    return applyWorkerPlan(
      plan,
      transferableBytes: transferableBytes,
      submitQueue: submitQueue,
    );
  }
}
