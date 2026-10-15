import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'budgets.dart';
import 'generator.dart';
import 'key.dart';
import 'payload.dart';
import 'probe.dart';
import 'record.dart';
import 'residency.dart';
import 'scheduler.dart';
import 'stats.dart';
import 'storage.dart';
import 'ticket.dart';
import 'tuning.dart';
import 'worker_pool.dart';

typedef ChunkPacketEncoder =
    Uint8List Function(int chunkX, int chunkZ, ChunkPayload payload);

final class ChunkPipeline {
  ChunkPipeline({
    required this.generator,
    required this.seed,
    this.storage,
    this.encoder,
    this.workers,
    ChunkConfig config = const ChunkConfig(),
    ResponsivenessProbe? probe,
  }) : config = config,
       tuning = ChunkTuning(config),
       probe = probe ?? ResponsivenessProbe(),
       residency = ChunkResidency(config),
       scheduler = ChunkScheduler(config);

  final ChunkGenerator generator;
  final int seed;
  final ChunkStorage? storage;
  final ChunkPacketEncoder? encoder;

  /// Initial configuration. Live-adjustable values are read from [tuning]
  /// after construction.
  final ChunkConfig config;

  /// Live-adjustable limits. The engine mutates this through
  /// `RuntimeConfigService`, never directly from the manager isolate.
  final ChunkTuning tuning;

  /// Generation pool. Null runs generation on the engine isolate. A pool
  /// reference stays valid while it drains after a live downsize.
  WorkerPool? workers;

  final ResponsivenessProbe probe;
  final ChunkResidency residency;
  final ChunkScheduler scheduler;
  final ChunkStats stats = ChunkStats();
  final List<void Function(ChunkKey key)> _ready = [];
  final Stopwatch _clock = Stopwatch()..start();
  final List<ChunkRecord> _writes = [];
  final List<Future<void>> _pending = [];
  final Set<Object> _pregenHolders = {};
  final List<WorkerPool> _drainingPools = [];
  Future<void> _flushTail = Future<void>.value();
  Future<void>? _closeFuture;
  Completer<void>? _idleWait;
  int _diskReads = 0;
  int _diskFlushes = 0;
  int _busy = 0;
  int _inlineUsedMicros = 0;
  int _lastAgeSweepMicros = 0;
  int _lastGroupCommitMicros = 0;
  bool _generationPaused = false;
  bool _closed = false;

  void addReadyListener(void Function(ChunkKey key) listener) =>
      _ready.add(listener);

  void removeReadyListener(void Function(ChunkKey key) listener) =>
      _ready.remove(listener);

  void addPregenHolder(Object holder) => _pregenHolders.add(holder);

  void removePregenHolder(Object holder) => _pregenHolders.remove(holder);

  ChunkRecord? record(ChunkKey key) => residency[key];

  Uint8List? encoded(ChunkKey key) {
    final current = residency[key];
    if (current == null || current.payload == null) return null;
    if (current.encoded != null) return current.encoded;
    final encode = encoder;
    if (encode == null) return null;
    current.encoded = encode(key.x, key.z, current.payload!);
    stats.encodes++;
    return current.encoded;
  }

  /// Records how long a delivered column waited between becoming resident and
  /// being handed to a socket.
  void noteDeliveryWait(int micros) =>
      stats.sample(stats.deliveryWaitMicros, micros);

  void addTicket(
    Object holder,
    ChunkKey key,
    TicketReason reason, {
    int? priorityRing,
  }) {
    if (_closed) return;
    if (reason == TicketReason.p2 && !_allowPrefetch) return;
    if (reason == TicketReason.p4 && !_allowPregen) return;
    final current = residency.obtain(key);
    final existed =
        current.tickets.isNotEmpty ||
        current.phase == ChunkPhase.reading ||
        current.phase == ChunkPhase.generating ||
        current.phase == ChunkPhase.resident;
    if (existed && current.tickets.isNotEmpty) stats.dedupHits++;
    final first = current.tickets.isEmpty;
    current.addTicket(holder, reason);
    if (priorityRing != null) {
      final previous = current.demandRing;
      if (previous == null || priorityRing < previous) {
        current.demandRing = priorityRing;
      }
    }
    current.fairnessHolder ??= holder;
    if (first) current.ticketedAtMicros = _now;
    residency.pin(current);
    if (current.phase == ChunkPhase.resident) return;
    if (current.phase == ChunkPhase.reading ||
        current.phase == ChunkPhase.generating) {
      return;
    }
    if (current.phase == ChunkPhase.failed) {
      final until = current.failedUntil;
      if (until != null && DateTime.now().isBefore(until)) return;
    }
    _queueOrWant(current);
    if (reason == TicketReason.p0 && !generator.heavy) {
      _tryStart(current, allowInline: true);
    }
  }

  void removeTicket(Object holder, ChunkKey key) {
    final current = residency[key];
    if (current == null) return;
    current.removeTicket(holder);
    if (current.referenced) return;
    if (current.phase == ChunkPhase.queued ||
        current.phase == ChunkPhase.wanted ||
        current.phase == ChunkPhase.failed) {
      if (current.phase != ChunkPhase.failed) stats.cancelled++;
      scheduler.remove(key);
      residency.drop(key);
      return;
    }
    residency.noteUnreferenced(current);
    _evict();
  }

  void releaseAll(Object holder) {
    final keys = [
      for (final record in residency.records.values)
        if (record.tickets.containsKey(holder)) record.key,
    ];
    for (final key in keys) {
      removeTicket(holder, key);
    }
  }

  /// Starts work and runs the inline generate budget. Does not wait for disk.
  void tick() {
    if (_closed) return;
    _inlineUsedMicros = 0;
    _refreshStats();
    _sweepAged();
    _promoteWanted();
    while (true) {
      final key = scheduler.pick(
        records: residency.records,
        pressure: probe.pressure,
        canStart: _canStart,
        nowMicros: _now,
      );
      if (key == null) break;
      final current = residency[key];
      if (current == null) {
        scheduler.remove(key);
        continue;
      }
      if (!_tryStart(current, allowInline: true)) break;
    }
    _evict();
    _maybeGroupCommit();
  }

  /// Runs queued work until referenced chunks are resident, failed, or still
  /// waiting on a cap, then flushes dirty payloads.
  Future<void> settle() async {
    for (var i = 0; i < 64; i++) {
      if (_closed) break;
      tick();
      if (_busy > 0) {
        await _waitBusy();
        continue;
      }
      if (_pending.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(_pending));
        continue;
      }
      final pending = residency.records.values.any(
        (record) =>
            record.referenced &&
            (record.phase == ChunkPhase.queued ||
                record.phase == ChunkPhase.wanted ||
                record.phase == ChunkPhase.reading ||
                record.phase == ChunkPhase.generating),
      );
      if (!pending) break;
      await Future<void>.delayed(Duration.zero);
    }
    await flushWrites();
    _refreshStats();
  }

  Future<void> pump() => settle();

  /// Stores dirty residents. Calls are serialized, so concurrent callers wait
  /// instead of dropping the batch or overlapping appends. [ChunkTuning.diskFlushes]
  /// is the upper bound; this writer uses one flush at a time.
  Future<void> flushWrites() {
    final run = _flushTail.then((_) => _flushBody());
    _flushTail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _flushBody() async {
    final storage = this.storage;
    if (storage == null || _writes.isEmpty) return;
    final cap = tuning.diskFlushes < 1 ? 1 : tuning.diskFlushes;
    if (_diskFlushes >= cap) return;
    _diskFlushes++;
    final batch = List<ChunkRecord>.of(_writes);
    _writes.clear();
    Object? failure;
    final started = DateTime.now().microsecondsSinceEpoch;
    try {
      for (final record in batch) {
        final payload = record.payload;
        if (payload == null || !record.dirty) continue;
        try {
          await storage.store(
            record.key,
            payload,
            generatorId: record.generatorId ?? generator.id,
            generatorVersion: record.generatorVersion ?? generator.version,
            regenerable: record.regenerable,
            playerModified: record.playerModified,
            finalized: true,
          );
          record.dirty = false;
          stats.dirtyWrites++;
        } catch (error) {
          failure = error;
          stats.storageFailures++;
          if (!_writes.contains(record)) _writes.add(record);
        }
      }
      await storage.flush();
      stats.storageWriteMicros +=
          DateTime.now().microsecondsSinceEpoch - started;
    } finally {
      _diskFlushes--;
      _evict();
      _refreshStats();
    }
    if (failure != null) throw failure;
  }

  /// Waits for in-flight reads, persists dirty chunks, then cancels worker
  /// jobs that have not finished. A second call awaits the same shutdown.
  /// Bytes are durable only after the storage flush inside this method, not
  /// across a power loss.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closed = true;
    _closeFuture = _closeBody();
    return _closeFuture!;
  }

  Future<void> _closeBody() async {
    Object? failure;
    try {
      for (var i = 0; i < 8 && _pending.isNotEmpty; i++) {
        await Future.wait(List<Future<void>>.of(_pending));
      }
      try {
        await flushWrites();
      } catch (error) {
        failure = error;
      }
      final pools = <WorkerPool>[?workers, ..._drainingPools];
      workers = null;
      _drainingPools.clear();
      for (final pool in pools) {
        try {
          await pool.close();
        } catch (error) {
          failure ??= error;
        }
      }
      try {
        await flushWrites();
      } catch (error) {
        failure ??= error;
      }
    } finally {
      try {
        await storage?.flush();
        await storage?.close();
      } catch (error) {
        failure ??= error;
      }
      probe.stop();
      _refreshStats();
    }
    if (failure != null) throw failure;
  }

  /// Live adjustment of the pending-generation queue bound. Jobs already
  /// accepted are kept.
  void setWorkerSubmitQueue(int limit) => workers?.setSubmitLimit(limit);

  /// Live worker-pool reconfiguration.
  ///
  /// Growing spawns isolates before they take work. Shrinking marks excess
  /// workers draining: they finish the job they hold, deliver the result, and
  /// close when idle. Existing deduplication and queue limits are unchanged
  /// because the pipeline keeps owning every record.
  Future<WorkerPlan> reconfigureWorkers(
    WorkerPlan plan, {
    int transferableBytes = 32768,
    int submitQueue = 256,
  }) async {
    if (_closed) return plan;
    final target = plan.count < 0 ? 0 : plan.count;
    if (target == 0) {
      final pool = workers;
      workers = null;
      if (pool != null && !_drainingPools.contains(pool)) {
        _drainingPools.add(pool);
        unawaited(_drainPool(pool));
      }
      return plan;
    }
    var pool = workers;
    if (pool == null || pool.isClosed) {
      pool = await WorkerPool.start(
        size: target,
        transferableBytes: transferableBytes,
        submitQueue: submitQueue,
      );
      workers = pool;
      return plan;
    }
    pool.setSubmitLimit(submitQueue);
    await pool.resize(target);
    return plan;
  }

  /// Waits for a draining pool to finish its accepted work, then closes it.
  /// Never cancels an in-flight generation.
  Future<void> _drainPool(WorkerPool pool) async {
    await pool.resize(0);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_closed && (pool.busy > 0 || pool.size > 0)) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    _drainingPools.remove(pool);
    await pool.close();
  }

  void _beginOp() {
    _busy++;
  }

  void _endOp() {
    if (_busy > 0) _busy--;
    if (_busy == 0) {
      final wait = _idleWait;
      _idleWait = null;
      if (wait != null && !wait.isCompleted) wait.complete();
    }
  }

  Future<void> _waitBusy() {
    if (_busy == 0) return Future<void>.value();
    return (_idleWait ??= Completer<void>()).future;
  }

  /// Test hook: deliver a worker-shaped result for [key].
  void debugDeliver({
    required ChunkKey key,
    required int epoch,
    ChunkPayload? payload,
    String? error,
    int cpuMicros = 0,
  }) {
    _onGenerateResult(
      key: key,
      epoch: epoch,
      payload: payload,
      error: error,
      cpuMicros: cpuMicros,
    );
  }

  bool get _allowPrefetch =>
      probe.pressure == Pressure.normal &&
      residency.accountedBytes < tuning.prefetchWaterBytes &&
      scheduler.queuedCount < tuning.queuedSoft;

  bool get _allowPregen =>
      probe.pressure == Pressure.normal &&
      residency.accountedBytes < tuning.lowWaterBytes &&
      scheduler.queuedCount < tuning.queuedSoft &&
      !_hasPlayerWork;

  bool get _hasPlayerWork {
    for (final record in residency.records.values) {
      if (record.highestReason.index <= TicketReason.p3.index &&
          record.phase != ChunkPhase.resident &&
          record.referenced) {
        return true;
      }
    }
    return false;
  }

  int get _now => _clock.elapsedMicroseconds;

  /// Promotes background work that waited too long. Slow cadence so the pick
  /// path stays free of a full residency scan.
  void _sweepAged() {
    if (_now - _lastAgeSweepMicros < 500000) return;
    _lastAgeSweepMicros = _now;
    scheduler.promoteAged(residency.records, _now);
  }

  void _queueOrWant(ChunkRecord record) {
    final reason = record.highestReason;
    final queued = scheduler.queuedCount;
    if (reason.isBackground && queued >= tuning.queuedSoft) {
      record.phase = ChunkPhase.wanted;
      return;
    }
    if (queued >= tuning.queuedHard) {
      record.phase = ChunkPhase.wanted;
      return;
    }
    if (stats.queuedBytes >= tuning.globalQueuedChunkBytes &&
        !reason.isPlayerRequired) {
      record.phase = ChunkPhase.wanted;
      return;
    }
    record.queuedAtMicros = _now;
    scheduler.enqueue(record);
  }

  void _promoteWanted() {
    final wanted =
        [
              for (final record in residency.records.values)
                if (record.phase == ChunkPhase.wanted && record.referenced)
                  record,
            ]
            ..sort(
              (a, b) => a.highestReason.index.compareTo(b.highestReason.index),
            );
    for (final record in wanted) {
      if (scheduler.queuedCount >= tuning.queuedHard) break;
      if (record.highestReason.isBackground &&
          scheduler.queuedCount >= tuning.queuedSoft) {
        continue;
      }
      if (stats.queuedBytes >= tuning.globalQueuedChunkBytes &&
          !record.highestReason.isPlayerRequired) {
        continue;
      }
      record.queuedAtMicros = _now;
      scheduler.enqueue(record);
    }
  }

  bool _canStart(ChunkRecord record) {
    if (_generationPaused && record.highestReason != TicketReason.p0) {
      return false;
    }
    if (probe.pressure == Pressure.critical &&
        record.highestReason != TicketReason.p0) {
      return false;
    }
    final globalCap = tuning.globalGenerationInFlight;
    if (_generationInFlight >= globalCap + tuning.p0Bonus &&
        record.highestReason != TicketReason.p0) {
      return false;
    }
    final holder = record.fairnessHolder;
    if (holder != null && _pregenHolders.contains(holder)) {
      final cap = _hasPlayerWork || probe.pressure != Pressure.normal
          ? tuning.pregenInFlightBusy
          : tuning.pregenInFlightIdle;
      if (_inFlightFor(holder) >= cap) return false;
      if (_pregenTicketCount() >= tuning.pregenTickets &&
          record.phase != ChunkPhase.queued) {
        return false;
      }
      return true;
    }
    if (holder == null) return true;
    final inFlight = _inFlightFor(holder);
    if (inFlight < tuning.perPlayerInFlight) return true;
    return record.highestReason == TicketReason.p0 &&
        inFlight < tuning.perPlayerInFlight + tuning.p0Bonus;
  }

  int get _generationInFlight {
    var n = 0;
    for (final record in residency.records.values) {
      if (record.phase == ChunkPhase.reading ||
          record.phase == ChunkPhase.generating) {
        n++;
      }
    }
    return n;
  }

  int _inFlightFor(Object holder) {
    var n = 0;
    for (final record in residency.records.values) {
      if (!record.tickets.containsKey(holder)) continue;
      if (record.phase == ChunkPhase.reading ||
          record.phase == ChunkPhase.generating) {
        n++;
      }
    }
    return n;
  }

  int _pregenTicketCount() {
    var n = 0;
    for (final record in residency.records.values) {
      for (final holder in record.tickets.keys) {
        if (_pregenHolders.contains(holder)) n++;
      }
    }
    return n;
  }

  bool _tryStart(ChunkRecord record, {required bool allowInline}) {
    if (record.phase != ChunkPhase.queued &&
        record.phase != ChunkPhase.wanted) {
      return false;
    }
    if (!_canStart(record)) return false;
    scheduler.remove(record.key);
    if (record.queuedAtMicros != 0) {
      stats.sample(stats.queuedWait, _now - record.queuedAtMicros);
    }
    if (storage != null) {
      return _startRead(record);
    }
    return _startGenerate(record, allowInline: allowInline);
  }

  bool _startRead(ChunkRecord record) {
    if (_diskReads >= tuning.diskReads) {
      scheduler.enqueue(record);
      return false;
    }
    record.phase = ChunkPhase.reading;
    record.jobEpoch++;
    record.startedAtMicros = _now;
    final epoch = record.jobEpoch;
    _diskReads++;
    stats.reads++;
    _beginOp();
    final started = DateTime.now().microsecondsSinceEpoch;
    _track(() async {
      try {
        final result = await storage!.lookup(record.key);
        final elapsed = DateTime.now().microsecondsSinceEpoch - started;
        stats.storageReadMicros += elapsed;
        stats.sample(stats.lookupMicros, elapsed);
        _onLookup(record.key, epoch, result);
      } catch (error) {
        stats.storageFailures++;
        _onLookupError(record.key, epoch, error);
      } finally {
        _diskReads--;
        _endOp();
      }
    }());
    return true;
  }

  void _track(Future<void> future) {
    _pending.add(future);
    future.whenComplete(() => _pending.remove(future));
  }

  void _onLookup(ChunkKey key, int epoch, ChunkLookup result) {
    final record = residency[key];
    if (record == null ||
        record.jobEpoch != epoch ||
        record.phase != ChunkPhase.reading) {
      stats.staleResults++;
      return;
    }
    if (_closed && result.kind != ChunkLookupKind.hit) {
      stats.cancelled++;
      scheduler.remove(key);
      if (record.referenced) {
        _fail(record);
      } else {
        residency.drop(key);
      }
      return;
    }
    switch (result.kind) {
      case ChunkLookupKind.hit:
        if (result.generatorId == generator.id &&
            result.generatorVersion == generator.version &&
            result.finalized) {
          stats.storageHits++;
          _admit(
            record,
            result.payload!,
            generatorId: result.generatorId,
            generatorVersion: result.generatorVersion,
            regenerable: result.regenerable,
            playerModified: result.playerModified,
            dirty: false,
          );
          return;
        }
        if (result.playerModified) {
          _admit(
            record,
            result.payload!,
            generatorId: result.generatorId,
            generatorVersion: result.generatorVersion,
            regenerable: false,
            playerModified: true,
            dirty: false,
          );
          return;
        }
        _startGenerate(record, allowInline: true);
        return;
      case ChunkLookupKind.miss:
        stats.storageMisses++;
        _startGenerate(record, allowInline: true);
        return;
      case ChunkLookupKind.corrupt:
        stats.failedLoads++;
        if (result.playerModified) {
          final raw = result.raw;
          final storage = this.storage;
          if (raw != null && storage != null) {
            _track(storage.quarantine(key, raw));
          }
          _fail(record);
          return;
        }
        _startGenerate(record, allowInline: true);
        return;
    }
  }

  void _onLookupError(ChunkKey key, int epoch, Object error) {
    final record = residency[key];
    if (record == null ||
        record.jobEpoch != epoch ||
        record.phase != ChunkPhase.reading) {
      return;
    }
    record.ioAttempts++;
    if (!_closed && record.ioAttempts < 3) {
      stats.retries++;
      record.phase = ChunkPhase.queued;
      scheduler.enqueue(record);
      return;
    }
    stats.failedLoads++;
    _fail(record);
    if (_closed && !record.referenced) residency.drop(key);
  }

  bool _startGenerate(ChunkRecord record, {required bool allowInline}) {
    record.phase = ChunkPhase.generating;
    record.jobEpoch++;
    record.startedAtMicros = _now;
    final epoch = record.jobEpoch;
    final pool = workers;
    if (pool != null && !pool.isClosed && pool.size > 0) {
      _beginOp();
      final submitted = pool.trySubmit(
        GenerateJob(
          epoch: epoch,
          key: record.key,
          seed: seed,
          generatorId: generator.id,
          generatorVersion: generator.version,
        ),
        onResult: (result) {
          try {
            _onGenerateResult(
              key: result.key,
              epoch: result.epoch,
              payload: result.payload,
              error: result.error,
              cpuMicros: result.cpuMicros,
              fromWorker: true,
            );
          } finally {
            _endOp();
          }
        },
      );
      if (!submitted) {
        _endOp();
        record.jobEpoch--;
        record.phase = ChunkPhase.queued;
        scheduler.enqueue(record);
        return false;
      }
      stats.workerJobs++;
      return true;
    }
    if (!allowInline) {
      record.jobEpoch--;
      record.phase = ChunkPhase.queued;
      scheduler.enqueue(record);
      return false;
    }
    if (_inlineUsedMicros >= tuning.inlineBudgetMicros &&
        record.highestReason != TicketReason.p0) {
      record.jobEpoch--;
      record.phase = ChunkPhase.queued;
      scheduler.enqueue(record);
      return false;
    }
    _beginOp();
    try {
      _generateInline(record, epoch);
    } finally {
      _endOp();
    }
    return true;
  }

  void _generateInline(ChunkRecord record, int epoch) {
    final clock = Stopwatch()..start();
    try {
      final payload = generator.generate(
        seed: seed,
        x: record.key.x,
        z: record.key.z,
      );
      final generateMicros = clock.elapsedMicroseconds;
      final finalizeClock = Stopwatch()..start();
      _finalize(payload);
      final finalizeMicros = finalizeClock.elapsedMicroseconds;
      _inlineUsedMicros += generateMicros + finalizeMicros;
      stats.generateMicros += generateMicros;
      stats.finalizeMicros += finalizeMicros;
      _onGenerateResult(
        key: record.key,
        epoch: epoch,
        payload: payload,
        cpuMicros: generateMicros,
      );
    } catch (error) {
      _onGenerateResult(
        key: record.key,
        epoch: epoch,
        error: error.toString(),
      );
    }
  }

  void _finalize(ChunkPayload payload) {
    if (payload.sections.isEmpty) {
      throw StateError('generated column has no sections');
    }
  }

  void _onGenerateResult({
    required ChunkKey key,
    required int epoch,
    ChunkPayload? payload,
    String? error,
    int cpuMicros = 0,
    bool fromWorker = false,
  }) {
    final record = residency[key];
    if (record == null ||
        record.jobEpoch != epoch ||
        record.phase != ChunkPhase.generating) {
      stats.staleResults++;
      return;
    }
    if (error != null || payload == null) {
      // A pool that shrank handed its queued job back. Re-queue it instead of
      // dropping the column; the next tick runs it inline or in the new pool.
      if (error == WorkerPool.requeuedError) {
        record.jobEpoch--;
        record.phase = ChunkPhase.queued;
        scheduler.enqueue(record);
        return;
      }
      if (_closed || error == 'cancelled') {
        stats.cancelled++;
        scheduler.remove(record.key);
        if (record.dirty) {
          _fail(record);
        } else {
          residency.drop(record.key);
        }
        return;
      }
      record.generateAttempts++;
      if (record.generateAttempts < 2) {
        stats.retries++;
        record.phase = ChunkPhase.queued;
        scheduler.enqueue(record);
        return;
      }
      _fail(record);
      return;
    }
    stats.generates++;
    if (fromWorker) stats.workerBytes += payload.byteLength;
    final keep =
        record.referenced || residency.accountedBytes < tuning.lowWaterBytes;
    if (!keep) {
      if (storage != null && !_closed) {
        _admit(
          record,
          payload,
          generatorId: generator.id,
          generatorVersion: generator.version,
          regenerable: true,
          playerModified: false,
          dirty: true,
        );
        return;
      }
      stats.cancelled++;
      residency.drop(key);
      return;
    }
    _admit(
      record,
      payload,
      generatorId: generator.id,
      generatorVersion: generator.version,
      regenerable: true,
      playerModified: false,
      dirty: storage != null,
    );
  }

  void _admit(
    ChunkRecord record,
    ChunkPayload payload, {
    required String? generatorId,
    required int? generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool dirty,
  }) {
    record.payload = payload;
    record.encoded = null;
    record.generatorId = generatorId;
    record.generatorVersion = generatorVersion;
    record.regenerable = regenerable;
    record.playerModified = playerModified;
    record.dirty = dirty;
    record.phase = ChunkPhase.resident;
    record.snapshotGeneration++;
    record.ioAttempts = 0;
    record.generateAttempts = 0;
    if (record.ticketedAtMicros != 0) {
      stats.sample(stats.ticketToResident, _now - record.ticketedAtMicros);
    }
    if (dirty && !_writes.contains(record)) {
      _writes.add(record);
      if (residency.accountedBytes + _queuedWriteBytes() >
          tuning.writeQueueBytes) {
        _generationPaused = true;
      }
    }
    if (!record.referenced) {
      residency.noteUnreferenced(record);
    }
    for (final listener in List.of(_ready)) {
      listener(record.key);
    }
    _evict();
  }

  int _queuedWriteBytes() {
    var n = 0;
    for (final record in _writes) {
      n += record.payload?.byteLength ?? 0;
    }
    return n;
  }

  void _fail(ChunkRecord record) {
    record.phase = ChunkPhase.failed;
    record.failedUntil = DateTime.now().add(const Duration(seconds: 5));
    scheduler.remove(record.key);
    if (!record.referenced) residency.drop(record.key);
  }

  /// Time-based group commit. Bounded by [ChunkTuning.diskFlushes] inside
  /// [flushWrites], which serializes callers.
  void _maybeGroupCommit() {
    if (_writes.isEmpty) return;
    final interval = tuning.groupCommitMillis;
    if (interval > 0 && _now - _lastGroupCommitMicros < interval * 1000) {
      return;
    }
    if (interval <= 0 && _writes.length < tuning.groupCommitChunks) return;
    _lastGroupCommitMicros = _now;
    unawaited(flushWrites());
  }

  void _evict() {
    if (residency.accountedBytes <= tuning.cacheBytes) {
      if (_queuedWriteBytes() < tuning.writeQueueBytes) {
        _generationPaused = false;
      }
      return;
    }
    var blocked = 0;
    for (final record in residency.records.values) {
      if (record.referenced && record.phase == ChunkPhase.resident) {
        blocked++;
      }
    }
    if (blocked > 0) stats.blockedEvictions += blocked;
    for (final key in residency.evictionCandidates()) {
      if (residency.accountedBytes <= tuning.cacheBytes) break;
      final record = residency[key];
      if (record == null || record.referenced) {
        residency.lru.remove(key);
        continue;
      }
      if (record.encoded != null) {
        record.encoded = null;
      }
      if (record.dirty) {
        if (!_writes.contains(record)) _writes.add(record);
        _generationPaused = true;
        continue;
      }
      if (record.phase == ChunkPhase.reading ||
          record.phase == ChunkPhase.generating) {
        continue;
      }
      residency.drop(key);
      stats.evictions++;
    }
  }

  void _refreshStats() {
    stats.queuedKeys = scheduler.queuedCount;
    stats.accountedBytes = residency.accountedBytes;
    stats.probeLatenessMicros = probe.lastLatenessMicros;
    stats.pressure = probe.pressure.name;
    final pool = workers;
    stats.workerActive = pool?.size ?? 0;
    stats.workerBusy = pool?.busy ?? 0;
    try {
      stats.rss = ProcessInfo.currentRss;
    } on Object {
      stats.rss = 0;
    }
    var resident = 0;
    var wanted = 0;
    var dirty = 0;
    var inFlight = 0;
    var queuedBytes = 0;
    final tickets = List<int>.filled(5, 0);
    for (final record in residency.records.values) {
      if (record.phase == ChunkPhase.resident) resident++;
      if (record.phase == ChunkPhase.wanted) wanted++;
      if (record.dirty) dirty++;
      if (record.phase == ChunkPhase.reading ||
          record.phase == ChunkPhase.generating) {
        inFlight++;
      }
      if (record.phase == ChunkPhase.queued) {
        queuedBytes += record.payload?.byteLength ?? 0;
      }
      for (final reason in record.tickets.values) {
        tickets[reason.index]++;
      }
    }
    stats.residentKeys = resident;
    stats.wantedKeys = wanted;
    stats.dirtyKeys = dirty;
    stats.inFlight = inFlight;
    stats.generating = inFlight;
    stats.queuedBytes = queuedBytes;
    stats.ticketsP0 = tickets[0];
    stats.ticketsP1 = tickets[1];
    stats.ticketsP2 = tickets[2];
    stats.ticketsP3 = tickets[3];
    stats.ticketsP4 = tickets[4];
  }
}
