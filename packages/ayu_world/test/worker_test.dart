import 'dart:async';

import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test('a worker isolate generates a packed column', () async {
    final pool = await WorkerPool.start(size: 1, submitQueue: 4);
    addTearDown(pool.close);
    const key = ChunkKey(worldId: ChunkKey.overworld, x: 0, z: 0);
    final finished = Completer<GenerateResult>();
    final done = pool.trySubmit(
      GenerateJob(
        epoch: 1,
        key: key,
        seed: 0,
        generatorId: FlatStonePadGenerator.idName,
        generatorVersion: 1,
      ),
      onResult: finished.complete,
    );
    expect(done, isTrue);
    final result = await finished.future.timeout(const Duration(seconds: 5));
    expect(result.error, isNull);
    expect(result.payload?.primaryBitmask, 1);
    expect(result.epoch, 1);
  });

  test('the busy generator is heavy and stays off the default pool', () {
    expect(const BusyChunkGenerator().heavy, isTrue);
    expect(const FlatStonePadGenerator().heavy, isFalse);
    expect(TerrainGeneratorV1().heavy, isTrue);
  });
}
