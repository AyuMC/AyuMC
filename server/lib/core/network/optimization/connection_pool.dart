import 'dart:io';

import '../enhanced_connection_handler.dart';

/// A load-balanced pool for managing client connections across worker groups.
///
/// The [ConnectionWorkerPool] distributes incoming connections across multiple
/// worker groups using a least-loaded-first strategy. This ensures even load
/// distribution and prevents bottlenecks.
///
/// Optimized for 5000+ concurrent connections with minimal overhead.
///
/// Example:
/// ```dart
/// final pool = ConnectionWorkerPool();
/// final workerIndex = pool.addConnection(socket);
/// ```
class ConnectionWorkerPool {
  final List<List<EnhancedConnectionHandler>> _workerGroups = [];
  final List<int> _workerLoads = [];
  int _nextWorkerIndex = 0;

  static const int kWorkerCount = 4;
  static const int kMaxConnectionsPerWorker = 1250;

  ConnectionWorkerPool() {
    _initializeWorkers();
  }

  void _initializeWorkers() {
    for (int i = 0; i < kWorkerCount; i++) {
      _workerGroups.add([]);
      _workerLoads.add(0);
    }

    print('[ConnectionWorkerPool] Initialized with $kWorkerCount workers');
  }

  /// Adds a new connection to the least-loaded worker group.
  ///
  /// Returns the index of the worker group that received the connection.
  int addConnection(Socket socket) {
    final workerIndex = _selectLeastLoadedWorker();
    final handler = EnhancedConnectionHandler(socket);

    _workerGroups[workerIndex].add(handler);
    _workerLoads[workerIndex]++;

    _setupConnectionCleanup(handler, workerIndex);

    return workerIndex;
  }

  int _selectLeastLoadedWorker() {
    int minLoad = _workerLoads[0];
    int minIndex = 0;

    for (int i = 1; i < _workerLoads.length; i++) {
      if (_workerLoads[i] < minLoad) {
        minLoad = _workerLoads[i];
        minIndex = i;
      }
    }

    if (minLoad >= kMaxConnectionsPerWorker) {
      return _nextWorkerIndex++ % kWorkerCount;
    }

    return minIndex;
  }

  void _setupConnectionCleanup(
    EnhancedConnectionHandler handler,
    int workerIndex,
  ) {
    handler.onClose = () {
      _workerGroups[workerIndex].remove(handler);
      _workerLoads[workerIndex]--;
    };
  }

  /// Returns the total number of active connections across all workers.
  int get totalConnections => _workerLoads.reduce((a, b) => a + b);

  /// Returns the current load for each worker group.
  List<int> get workerLoads => List.unmodifiable(_workerLoads);

  /// Closes all connections in all worker groups.
  void closeAll() {
    for (final group in _workerGroups) {
      for (final handler in group) {
        handler.close();
      }
      group.clear();
    }

    for (int i = 0; i < _workerLoads.length; i++) {
      _workerLoads[i] = 0;
    }
  }
}
