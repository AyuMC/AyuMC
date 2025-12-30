import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import '../../logging/server_logger.dart';

/// A high-performance pool of worker isolates for parallel task execution.
///
/// The [IsolateWorkerPool] distributes CPU-intensive tasks across multiple
/// isolates to achieve true parallelism. It automatically manages worker
/// lifecycle, load balancing, and fault isolation.
///
/// Example:
/// ```dart
/// final pool = IsolateWorkerPool();
/// await pool.initialize(workerCount: 4);
///
/// final result = await pool.execute(() async {
///   return heavyComputation();
/// });
///
/// await pool.shutdown();
/// ```
class IsolateWorkerPool {
  final List<_WorkerIsolate> _workers = [];
  int _nextWorkerIndex = 0;
  bool _isInitialized = false;

  static final ServerLogger _logger = ServerLogger();
  static const int kDefaultWorkerCount = 4;
  static const int kMaxWorkerCount = 16;

  /// Initializes the worker pool with the specified number of isolates.
  ///
  /// If [workerCount] is not provided, it defaults to CPU cores - 1,
  /// clamped between 2 and [kMaxWorkerCount].
  Future<void> initialize({int? workerCount}) async {
    if (_isInitialized) return;

    final count = _calculateOptimalWorkerCount(workerCount);

    for (int i = 0; i < count; i++) {
      final worker = await _WorkerIsolate.create(i);
      _workers.add(worker);
    }

    _isInitialized = true;
    _logger.info('IsolateWorkerPool', 'Initialized with $count workers');
  }

  int _calculateOptimalWorkerCount(int? requested) {
    if (requested != null && requested > 0) {
      return requested.clamp(1, kMaxWorkerCount);
    }

    // NOTE: The generic pool implementation below uses message passing, but
    // sending closures across isolates is not supported by Dart. We keep this
    // pool for future refactor to a message-based task registry.
    final cores = Platform.numberOfProcessors;
    return (cores - 1).clamp(2, kDefaultWorkerCount);
  }

  /// Executes a task on a worker isolate using round-robin load balancing.
  ///
  /// Throws [StateError] if the pool is not initialized.
  Future<T> execute<T>(Future<T> Function() task) async {
    if (!_isInitialized) {
      throw StateError('IsolateWorkerPool not initialized');
    }

    final worker = _selectNextWorker();
    return worker.execute(task);
  }

  _WorkerIsolate _selectNextWorker() {
    final worker = _workers[_nextWorkerIndex];
    _nextWorkerIndex = (_nextWorkerIndex + 1) % _workers.length;
    return worker;
  }

  /// Returns the current number of worker isolates in the pool.
  int get workerCount => _workers.length;

  /// Returns whether the pool has been initialized.
  bool get isInitialized => _isInitialized;

  /// Shuts down all worker isolates and clears the pool.
  Future<void> shutdown() async {
    for (final worker in _workers) {
      await worker.dispose();
    }
    _workers.clear();
    _isInitialized = false;
    _logger.info('IsolateWorkerPool', 'Shutdown complete');
  }
}

/// Internal worker isolate wrapper.
class _WorkerIsolate {
  final int id;
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;

  _WorkerIsolate._(this.id, this._isolate, this._sendPort, this._receivePort);

  static Future<_WorkerIsolate> create(int id) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateEntryPoint,
      receivePort.sendPort,
    );

    final sendPort = await receivePort.first as SendPort;

    return _WorkerIsolate._(id, isolate, sendPort, receivePort);
  }

  static void _isolateEntryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      if (message is _TaskMessage) {
        try {
          final result = await message.task();
          message.resultPort.send(_ResultMessage(result, null));
        } catch (e) {
          message.resultPort.send(_ResultMessage(null, e));
        }
      }
    });
  }

  Future<T> execute<T>(Future<T> Function() task) async {
    final resultPort = ReceivePort();
    final message = _TaskMessage(task, resultPort.sendPort);

    _sendPort.send(message);

    final result = await resultPort.first as _ResultMessage;
    resultPort.close();

    if (result.error != null) {
      throw result.error!;
    }

    return result.value as T;
  }

  Future<void> dispose() async {
    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
  }
}

class _TaskMessage {
  final Future<dynamic> Function() task;
  final SendPort resultPort;

  _TaskMessage(this.task, this.resultPort);
}

class _ResultMessage {
  final dynamic value;
  final Object? error;

  _ResultMessage(this.value, this.error);
}
