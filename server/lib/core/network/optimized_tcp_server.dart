import 'dart:io';
import '../constants/network_constants.dart';
import 'keep_alive/keep_alive_manager.dart';
import 'optimization/adaptive_scheduler.dart';
import 'optimization/connection_pool.dart';
import 'optimization/isolate_pool.dart';
import 'optimization/memory_pool.dart';
import 'optimization/network_statistics.dart';
import 'utils/network_logger.dart';

/// A high-performance TCP server optimized for handling thousands of
/// concurrent connections.
///
/// The [HighPerformanceTcpServer] integrates multiple optimization strategies
/// including multi-threading, memory pooling, connection pooling, adaptive
/// scheduling, and comprehensive statistics tracking.
///
/// Example:
/// ```dart
/// final server = HighPerformanceTcpServer();
/// await server.start(port: 25565);
///
/// final stats = server.getStatistics();
/// print('Active connections: ${stats['connectionsActive']}');
///
/// await server.stop();
/// ```
class HighPerformanceTcpServer {
  ServerSocket? _server;
  final ConnectionWorkerPool _connectionPool = ConnectionWorkerPool();
  final IsolateWorkerPool _isolatePool = IsolateWorkerPool();
  final BufferMemoryPool _memoryPool = BufferMemoryPool();
  final PerformanceAdaptiveScheduler _scheduler =
      PerformanceAdaptiveScheduler();
  final NetworkPerformanceStatistics _statistics =
      NetworkPerformanceStatistics();
  final KeepAliveManager _keepAliveManager = KeepAliveManager();

  bool _isRunning = false;

  /// Starts the high-performance TCP server on the specified [port].
  ///
  /// Initializes all optimization systems and begins listening for connections.
  /// Throws [SocketException] if the port is already in use.
  Future<void> start({int port = NetworkConstants.defaultPort}) async {
    if (_isRunning) {
      NetworkLogger.info('HighPerformanceTcpServer', 'Already running');
      return;
    }

    await _initializeAllOptimizations();

    _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );

    _startListening();
    _scheduler.start();
    _keepAliveManager.start();

    _isRunning = true;
    NetworkLogger.info('HighPerformanceTcpServer', 'Started on port $port');
    _printOptimizationStatus();
  }

  Future<void> _initializeAllOptimizations() async {
    await _isolatePool.initialize(workerCount: 4);
    _memoryPool.initialize();

    NetworkLogger.info(
      'HighPerformanceTcpServer',
      'All optimizations initialized',
    );
  }

  void _startListening() {
    _server?.listen(
      _handleConnection,
      onError: _handleError,
      cancelOnError: false,
    );
  }

  void _handleConnection(Socket socket) {
    _configureSocketOptions(socket);

    final workerIndex = _connectionPool.addConnection(socket);
    _statistics.recordConnectionOpened();

    NetworkLogger.info(
      'HighPerformanceTcpServer',
      'Client connected: ${socket.remoteAddress.address}:'
          '${socket.remotePort} -> Worker $workerIndex',
    );
  }

  void _configureSocketOptions(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
  }

  void _handleError(Object error) {
    NetworkLogger.error('HighPerformanceTcpServer', 'Error: $error');
  }

  void _printOptimizationStatus() {
    print('┌────────────────────────────────────────┐');
    print('│   HIGH PERFORMANCE SERVER STATUS       │');
    print('├────────────────────────────────────────┤');
    print('│ ✓ Isolate Workers: ${_isolatePool.workerCount}');
    print('│ ✓ Connection Workers: ${ConnectionWorkerPool.kWorkerCount}');
    print('│ ✓ Memory Pooling: Active');
    print('│ ✓ Adaptive Scheduler: Active');
    print('│ ✓ Keep Alive System: Active');
    print('│ ✓ Statistics Tracking: Active');
    print('└────────────────────────────────────────┘');
  }

  /// Returns comprehensive statistics about server performance.
  Map<String, dynamic> getStatistics() {
    return {
      ..._statistics.toMap(),
      'totalConnections': _connectionPool.totalConnections,
      'workerLoads': _connectionPool.workerLoads,
      'tickRate': _scheduler.currentTickRate,
      'memoryPoolStats': _memoryPool.getStatistics(),
      'isRunning': _isRunning,
    };
  }

  /// Returns whether the server is currently running.
  bool get isRunning => _isRunning;

  /// Stops the server and shuts down all optimization systems.
  Future<void> stop() async {
    if (!_isRunning) {
      NetworkLogger.info('HighPerformanceTcpServer', 'Not running');
      return;
    }

    _keepAliveManager.stop();
    _scheduler.stop();
    _connectionPool.closeAll();
    await _server?.close();
    await _isolatePool.shutdown();

    _isRunning = false;
    NetworkLogger.info('HighPerformanceTcpServer', 'Stopped');
  }
}
