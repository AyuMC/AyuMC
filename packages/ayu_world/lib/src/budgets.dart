import 'dart:io';

/// Safety caps and initial tuning values.
///
/// The values here are the *initial* configuration for a pipeline. Values that
/// can be changed while the server runs are read from [ChunkTuning], which is
/// seeded from this object at construction time. See `docs/` and the manager
/// configuration screen for the live-adjustable subset.
///
/// None of these numbers is a measured performance target. They are bounded
/// safety limits whose starting values were chosen from benchmark runs.
final class ChunkConfig {
  const ChunkConfig({
    this.workers = -1,
    this.maxWorkers = 8,
    this.cacheMiB = 256,
    this.sendSliceBytes = 256 * 1024,
    this.queuedSoft = 4096,
    this.queuedHard = 8192,
    this.perPlayerInFlight = 16,
    this.p0Bonus = 9,
    this.diskReads = 8,
    this.diskFlushes = 2,
    this.pregenTickets = 16,
    this.pregenInFlightBusy = 1,
    this.pregenInFlightIdle = 2,
    this.inlineBudget = const Duration(milliseconds: 2),
    this.globalQueuedChunkBytes = 32 * 1024 * 1024,
    this.workerSubmitQueue = 256,
    this.transferableBytes = 32 * 1024,
    this.writeQueueBytes = 32 * 1024 * 1024,
    this.groupCommitChunks = 32,
    this.groupCommit = const Duration(milliseconds: 50),
    this.globalGenerationInFlight = 64,
    this.viewChunks = defaultViewChunks,
    this.compressionThreshold = defaultCompressionThreshold,
    this.sendIntervalMillis = 50,
    this.globalSendBytes = 2 * 1024 * 1024,
    this.perPlayerPendingChunks = 512,
    this.perPlayerQueuedBytes = 8 * 1024 * 1024,
  });

  /// Balanced server view cap for new installations. Measured against 10 and
  /// 4 in `packages/ayu_protocol_189/benchmark/streaming_bench.dart`.
  static const defaultViewChunks = 6;

  /// Protocol-47 compression threshold. `-1` disables compression, which the
  /// protocol expresses by not sending Set Compression at all.
  static const defaultCompressionThreshold = 256;

  /// Server chunk radius sent when the client does not request a smaller one.
  final int viewChunks;

  /// `-1` selects [resolveWorkerPlan] automatic mode. `0` is inline. A
  /// positive value is a fixed isolate count.
  final int workers;
  final int maxWorkers;
  final int cacheMiB;
  final int sendSliceBytes;
  final int queuedSoft;
  final int queuedHard;
  final int perPlayerInFlight;
  final int p0Bonus;
  final int diskReads;
  final int diskFlushes;
  final int pregenTickets;
  final int pregenInFlightBusy;
  final int pregenInFlightIdle;
  final Duration inlineBudget;
  final int globalQueuedChunkBytes;
  final int workerSubmitQueue;
  final int transferableBytes;
  final int writeQueueBytes;
  final int groupCommitChunks;
  final Duration groupCommit;

  /// Upper bound on generation work in flight across every holder.
  final int globalGenerationInFlight;

  /// `-1` disables transport compression. `0` compresses every frame. A
  /// positive value compresses frames whose payload reaches this size.
  final int compressionThreshold;

  /// Interval of the per-endpoint chunk delivery tick.
  final int sendIntervalMillis;

  /// Bytes per [sendIntervalMillis] shared by every connection.
  final int globalSendBytes;

  /// Most resident-but-unsent columns one player may hold at once.
  final int perPlayerPendingChunks;

  /// Most bytes of resident-but-unsent column packets one player may hold.
  final int perPlayerQueuedBytes;

  int get cacheBytes => cacheMiB * 1024 * 1024;

  int get lowWaterBytes => cacheBytes * 4 ~/ 5;

  int get prefetchWaterBytes => cacheBytes * 9 ~/ 10;
}

enum Pressure { normal, degraded, critical }

enum WorkerMode { automatic, inline, fixed }

final class WorkerPlan {
  const WorkerPlan({
    required this.mode,
    required this.count,
    required this.reason,
  });

  final WorkerMode mode;
  final int count;
  final String reason;
}

/// Maps the configured worker request to a pool size.
///
/// [requested] `-1` is automatic, `0` is inline, and a positive value is a
/// fixed count clamped to [maxWorkers]. Automatic starts a pool only for a
/// CPU-heavy generator on a machine with more than one processor.
WorkerPlan resolveWorkerPlan({
  required int requested,
  required bool heavy,
  int maxWorkers = 8,
  int? processors,
}) {
  final cap = maxWorkers < 1 ? 1 : maxWorkers;
  final cores = processors ?? Platform.numberOfProcessors;
  if (requested == 0) {
    return WorkerPlan(
      mode: WorkerMode.inline,
      count: 0,
      reason: heavy
          ? 'chunks.workers is 0; CPU-heavy generation runs on the engine isolate. Omit chunks.workers or set -1 for automatic workers.'
          : 'chunks.workers is 0; generation stays on the engine isolate.',
    );
  }
  if (requested > 0) {
    final n = requested > cap ? cap : requested;
    return WorkerPlan(
      mode: WorkerMode.fixed,
      count: n,
      reason: n != requested
          ? 'chunks.workers $requested clamped to maxWorkers $cap'
          : 'chunks.workers is $requested',
    );
  }
  if (!heavy) {
    return const WorkerPlan(
      mode: WorkerMode.automatic,
      count: 0,
      reason: 'generator is not CPU-heavy; automatic mode stays inline',
    );
  }
  if (cores <= 1) {
    return const WorkerPlan(
      mode: WorkerMode.automatic,
      count: 0,
      reason: 'single processor; automatic mode stays inline',
    );
  }
  var n = cores - 1;
  if (n < 1) n = 1;
  if (n > cap) n = cap;
  return WorkerPlan(
    mode: WorkerMode.automatic,
    count: n,
    reason:
        'automatic from $cores processors, leaving 1 for the engine, max $cap',
  );
}
