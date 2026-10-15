import 'dart:io';

import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test('pregen skips stored columns and resumes from the cursor file', () async {
    final root = await Directory.systemTemp.createTemp('ayu-pregen-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final storage = MemoryChunkStorage();
    final existing = ChunkKey(worldId: ChunkKey.overworld, x: -1, z: -1);
    await storage.store(
      existing,
      const FlatStonePadGenerator().generate(seed: 0, x: -1, z: -1),
      generatorId: FlatStonePadGenerator.idName,
      generatorVersion: 1,
      regenerable: true,
      playerModified: false,
      finalized: true,
    );
    final pipeline = ChunkPipeline(
      generator: const FlatStonePadGenerator(),
      seed: 0,
      storage: storage,
    );
    addTearDown(pipeline.close);
    final demand = ChunkDemand(pipeline);
    final pregen = PregenService(
      directory: Directory('${root.path}${Platform.pathSeparator}pregen'),
      pipeline: pipeline,
      demand: demand,
      storage: storage,
      generatorId: FlatStonePadGenerator.idName,
      generatorVersion: 1,
      workingSet: 16,
    );
    addTearDown(pregen.close);
    final task = pregen.start(centerX: 0, centerZ: 0, radius: 1, id: 't1');
    expect(task.total, 9);
    await pregen.pump();
    await pipeline.pump();
    pregen.onResident(ChunkKey(worldId: ChunkKey.overworld, x: 0, z: 0));
    expect(task.skipped, greaterThan(0));
    expect(pregen.statusText(), contains('t1'));
    await pregen.close();

    final again = PregenService(
      directory: Directory('${root.path}${Platform.pathSeparator}pregen'),
      pipeline: pipeline,
      demand: demand,
      storage: storage,
      generatorId: FlatStonePadGenerator.idName,
      generatorVersion: 1,
    );
    await again.load();
    expect(again.tasks['t1']?.cursor, greaterThan(0));
    await again.close();
  });
}
