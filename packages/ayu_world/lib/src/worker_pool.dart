import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'chunk_worker.dart';
import 'key.dart';
import 'payload.dart';

final class GenerateJob {
  GenerateJob({
    required this.epoch,
    required this.key,
    required this.seed,
    required this.generatorId,
    required this.generatorVersion,
  });

  final int epoch;
  final ChunkKey key;
  final int seed;
  final String generatorId;
  final int generatorVersion;
}

final class GenerateResult {
  GenerateResult({
    required this.epoch,
    required this.key,
    this.payload,
    this.error,
    this.cpuMicros = 0,
  });

  final int epoch;
  final ChunkKey key;
  final ChunkPayload? payload;
  final String? error;
  final int cpuMicros;
}

/// Isolate pool for chunk generation with live resizing.
///
/// Resizing never kills an in-flight job. Shrinking marks the excess workers
/// as draining: they keep the job they hold, deliver its result normally, and
/// are closed when they become idle. [resize] to zero returns queued (not yet
/// started) jobs to the caller with [requeuedError] so the pipeline can run
/// them inline instead of leaving a record stuck in `generating`.
final class WorkerPool {
  WorkerPool._({
    required int transferableBytes,
    required int submitQueue,
  }) : _transferableBytes = transferableBytes,
       _submitLimit = submitQueue;

  /// Reported when a queued job is handed back instead of run.
  static const requeuedError = 'requeued';

  final int _transferableBytes;
  int _submitLimit;
  final List<_Worker> _workers = [];
  final List<_Pending> _queued = [];
  var _closed = false;

  static Future<WorkerPool> start({
    required int size,
    int transferableBytes = 32768,
    int submitQueue = 256,
  }) async {
    final pool = WorkerPool._(
      transferableBytes: transferableBytes,
      submitQueue: submitQueue,
    );
    for (var i = 0; i < size; i++) {
      await pool._spawn();
    }
    return pool;
  }

  /// Workers accepting new work.
  int get size => _workers.where((worker) => !worker.draining).length;

  /// Workers still finishing a job before they close.
  int get draining => _workers.where((worker) => worker.draining).length;

  int get busy => _workers.where((worker) => worker.job != null).length;

  int get queuedJobs => _queued.length;

  int get submitLimit => _submitLimit;

  /// Live adjustment of the pending-generation queue bound. Jobs already
  /// accepted are never dropped by a change.
  void setSubmitLimit(int limit) {
    _submitLimit = limit < 1 ? 1 : limit;
  }

  bool get isClosed => _closed;

  bool trySubmit(
    GenerateJob job, {
    required void Function(GenerateResult result) onResult,
  }) {
    if (_closed) return false;
    final idle = _idle();
    if (idle != null) {
      idle.send(job, onResult, _transferableBytes);
      return true;
    }
    if (size == 0) return false;
    if (_queued.length >= _submitLimit) return false;
    _queued.add(_Pending(job, onResult));
    return true;
  }

  /// Grows or shrinks the accepting set. Grows before the new plan is used and
  /// drains afterwards, so submitted work is never dropped silently.
  Future<int> resize(int target) async {
    if (_closed) return 0;
    final wanted = target < 0 ? 0 : target;
    var active = _workers.where((worker) => !worker.draining).toList();
    if (wanted > active.length) {
      for (var i = active.length; i < wanted; i++) {
        await _spawn();
      }
    } else if (wanted < active.length) {
      var excess = active.length - wanted;
      active.sort((a, b) {
        final aIdle = a.job == null ? 0 : 1;
        final bIdle = b.job == null ? 0 : 1;
        return aIdle.compareTo(bIdle);
      });
      for (final worker in active) {
        if (excess == 0) break;
        worker.draining = true;
        excess--;
        _sweep();
      }
    }
    if (size == 0) _returnQueued();
    _drain();
    return size;
  }

  Future<void> close() async {
    _closed = true;
    final dropped = List<_Pending>.of(_queued);
    _queued.clear();
    for (final pending in dropped) {
      pending.onResult(
        GenerateResult(
          epoch: pending.job.epoch,
          key: pending.job.key,
          error: 'cancelled',
        ),
      );
    }
    for (final worker in List<_Worker>.of(_workers)) {
      final pending = worker.job;
      worker.job = null;
      pending?.onResult(
        GenerateResult(
          epoch: pending.job.epoch,
          key: pending.job.key,
          error: 'cancelled',
        ),
      );
      await worker.close();
    }
    _workers.clear();
  }

  Future<void> _spawn() async {
    final worker = _Worker(_workers.length);
    await worker.start(
      onResult: (result) {
        _complete(worker, result);
      },
      onDeath: () {
        _revive(worker);
      },
    );
    _workers.add(worker);
  }

  /// Hands queued jobs back so the pipeline can re-queue them. Used when the
  /// pool has no accepting worker left.
  void _returnQueued() {
    if (_queued.isEmpty) return;
    final dropped = List<_Pending>.of(_queued);
    _queued.clear();
    for (final pending in dropped) {
      pending.onResult(
        GenerateResult(
          epoch: pending.job.epoch,
          key: pending.job.key,
          error: requeuedError,
        ),
      );
    }
  }

  void _complete(_Worker worker, GenerateResult result) {
    final pending = worker.job;
    worker.job = null;
    pending?.onResult(result);
    _sweep();
    _drain();
  }

  void _drain() {
    if (_queued.isEmpty) return;
    while (_queued.isNotEmpty) {
      final idle = _idle();
      if (idle == null) return;
      final next = _queued.removeAt(0);
      idle.send(next.job, next.onResult, _transferableBytes);
    }
  }

  _Worker? _idle() {
    for (final worker in _workers) {
      if (!worker.draining && worker.alive && worker.job == null) {
        return worker;
      }
    }
    return null;
  }

  /// Closes draining workers that finished their work. The close is fire and
  /// forget: the isolate is already idle.
  void _sweep() {
    final finished = [
      for (final worker in _workers)
        if (worker.draining && worker.job == null) worker,
    ];
    for (final worker in finished) {
      _workers.remove(worker);
      unawaited(worker.close());
    }
  }

  void _revive(_Worker worker) {
    final pending = worker.job;
    worker.job = null;
    worker.alive = false;
    if (pending != null) {
      pending.onResult(
        GenerateResult(
          epoch: pending.job.epoch,
          key: pending.job.key,
          error: 'worker died',
        ),
      );
    }
    if (_closed || worker.draining) {
      _workers.remove(worker);
      unawaited(worker.close());
      return;
    }
    worker.deaths++;
    if (worker.deaths > 3) {
      _workers.remove(worker);
      unawaited(worker.close());
      return;
    }
    unawaited(
      worker.start(
        onResult: (result) => _complete(worker, result),
        onDeath: () => _revive(worker),
      ),
    );
  }
}

final class _Pending {
  _Pending(this.job, this.onResult);
  final GenerateJob job;
  final void Function(GenerateResult result) onResult;
}

final class _Worker {
  _Worker(this.index);

  final int index;
  int deaths = 0;
  bool draining = false;
  bool alive = true;
  Isolate? isolate;
  SendPort? commands;
  ReceivePort? incoming;
  ReceivePort? errors;
  ReceivePort? exits;
  _Pending? job;
  var _ready = Completer<void>();

  Future<void> start({
    required void Function(GenerateResult result) onResult,
    required void Function() onDeath,
  }) async {
    incoming = ReceivePort();
    errors = ReceivePort();
    exits = ReceivePort();
    _ready = Completer<void>();
    isolate = await Isolate.spawn(
      serveChunkWorker,
      incoming!.sendPort,
      errorsAreFatal: false,
      onError: errors!.sendPort,
      onExit: exits!.sendPort,
      debugName: 'ayu-chunk-$index',
    );
    incoming!.listen((message) {
      if (message is! Map) return;
      final map = message.cast<String, Object?>();
      if (map['op'] == 'ready') {
        commands = map['port'] as SendPort;
        alive = true;
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      if (map['op'] == 'result') {
        onResult(_decode(map));
      }
    });
    errors!.listen((_) {});
    exits!.listen((_) => onDeath());
    await _ready.future.timeout(const Duration(seconds: 5));
  }

  void send(
    GenerateJob job,
    void Function(GenerateResult result) onResult,
    int transferableBytes,
  ) {
    this.job = _Pending(job, onResult);
    commands!.send({
      'op': 'generate',
      'epoch': job.epoch,
      'worldId': job.key.worldId,
      'x': job.key.x,
      'z': job.key.z,
      'seed': job.seed,
      'generatorId': job.generatorId,
      'generatorVersion': job.generatorVersion,
      'transferableBytes': transferableBytes,
    });
  }

  Future<void> close() async {
    incoming?.close();
    errors?.close();
    exits?.close();
    isolate?.kill(priority: Isolate.beforeNextEvent);
    isolate = null;
    alive = false;
  }
}

GenerateResult _decode(Map<String, Object?> map) {
  final key = ChunkKey(
    worldId: map['worldId'] as String,
    x: map['x'] as int,
    z: map['z'] as int,
  );
  final epoch = map['epoch'] as int;
  final error = map['error'] as String?;
  if (error != null) {
    return GenerateResult(
      epoch: epoch,
      key: key,
      error: error,
      cpuMicros: map['cpuMicros'] as int? ?? 0,
    );
  }
  final raw = map['payload'];
  Uint8List bytes;
  if (raw is TransferableTypedData) {
    bytes = raw.materialize().asUint8List();
  } else if (raw is Uint8List) {
    bytes = raw;
  } else {
    return GenerateResult(
      epoch: epoch,
      key: key,
      error: 'missing payload',
    );
  }
  return GenerateResult(
    epoch: epoch,
    key: key,
    payload: ChunkPayload.unpack(bytes),
    cpuMicros: map['cpuMicros'] as int? ?? 0,
  );
}
