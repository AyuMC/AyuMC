// Throughput of TerrainGeneratorV1. From packages/ayu_world:
// dart run benchmark/terrain_bench.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_world/ayu_world.dart';

Future<void> main() async {
  const seed = 42;
  const sizes = [64, 256, 512];
  final auto = resolveWorkerPlan(
    requested: -1,
    heavy: true,
    maxWorkers: 8,
  );
  stdout.writeln(
    'terrain_v1 seed=$seed autoWorkers=${auto.count} (${auto.reason})',
  );
  stdout.writeln('transfer=TransferableTypedData at ${32 * 1024} bytes');
  final modes = <(String, int)>[
    ('inline', 0),
    ('workers=1', 1),
    ('workers=2', 2),
    ('workers=4', 4),
    ('automatic', auto.count),
  ];
  for (final size in sizes) {
    stdout.writeln('');
    stdout.writeln('size=$size');
    String? firstHash;
    for (final mode in modes) {
      await _run(mode.$1, mode.$2, 16, warmup: true);
      final result = await _run(mode.$1, mode.$2, size, warmup: false);
      firstHash ??= result.hash;
      if (result.hash != firstHash) {
        stderr.writeln(
          'HASH MISMATCH ${mode.$1} size=$size ${result.hash} != $firstHash',
        );
        exitCode = 1;
      }
      stdout.writeln(
        '${mode.$1}: wall_ms=${result.wallMs} chunks_per_s=${result.rate.toStringAsFixed(1)} '
        'gen_p50_us=${result.p50} gen_p95_us=${result.p95} gen_p99_us=${result.p99} '
        'queue_wait_p50_us=${result.queueP50} payload_bytes=${result.bytes} '
        'worker_jobs=${result.workerJobs} hash=${result.hash}',
      );
    }
  }
}

Future<({
  int wallMs,
  double rate,
  int p50,
  int p95,
  int p99,
  int queueP50,
  int bytes,
  int workerJobs,
  String hash,
})> _run(String label, int workers, int count, {required bool warmup}) async {
  WorkerPool? pool;
  if (workers > 0) {
    pool = await WorkerPool.start(size: workers, submitQueue: 256);
  }
  final pipeline = ChunkPipeline(
    generator: TerrainGeneratorV1(),
    seed: 42,
    workers: pool,
    encoder: (x, z, payload) => Uint8List(0),
    config: ChunkConfig(workers: workers, perPlayerInFlight: 64),
  );
  final holder = Object();
  for (var i = 0; i < count; i++) {
    pipeline.addTicket(
      holder,
      ChunkKey(worldId: ChunkKey.overworld, x: i % 32, z: i ~/ 32),
      TicketReason.p0,
    );
  }
  final clock = Stopwatch()..start();
  await pipeline.settle();
  clock.stop();
  var bytes = 0;
  var hash = 2166136261;
  for (var i = 0; i < count; i++) {
    final packed = pipeline
        .record(ChunkKey(worldId: ChunkKey.overworld, x: i % 32, z: i ~/ 32))!
        .payload!
        .pack();
    bytes += packed.length;
    for (final b in packed) {
      hash = ((hash ^ b) * 16777619) & 0xFFFFFFFF;
    }
  }
  final samples = List<int>.of(pipeline.stats.ticketToResident)..sort();
  final waits = List<int>.of(pipeline.stats.queuedWait)..sort();
  final result = (
    wallMs: clock.elapsedMilliseconds,
    rate: count * 1000 / (clock.elapsedMilliseconds == 0 ? 1 : clock.elapsedMilliseconds),
    p50: _pct(samples, 0.50),
    p95: _pct(samples, 0.95),
    p99: _pct(samples, 0.99),
    queueP50: _pct(waits, 0.50),
    bytes: bytes,
    workerJobs: pipeline.stats.workerJobs,
    hash: hash.toRadixString(16),
  );
  await pipeline.close();
  if (warmup) {
    stdout.writeln('warmup $label n=$count wall_ms=${result.wallMs}');
  }
  return result;
}

int _pct(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = (sorted.length * p).ceil() - 1;
  return sorted[i < 0 ? 0 : (i >= sorted.length ? sorted.length - 1 : i)];
}
