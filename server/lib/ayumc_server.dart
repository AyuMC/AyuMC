import 'core/logging/server_logger.dart';
import 'core/network/high_performance_server.dart';

enum ServerState { stopped, starting, running, stopping, restarting }

/// Main AyuMC Server class with ultra-high performance architecture.
///
/// Uses multi-threading, memory pooling, and advanced optimizations.
class AyuMCServer {
  static ServerState state = ServerState.stopped;
  static final HighPerformanceTcpServer _server = HighPerformanceTcpServer();
  static final ServerLogger _logger = ServerLogger();

  static Future<void> start() async {
    if (state == ServerState.running) {
      return;
    }

    state = ServerState.starting;
    _logger.info('Server', 'Starting AyuMC Server...');
    _logger.info('Server', 'Initializing high-performance systems...');

    try {
      await _server.start();
      state = ServerState.running;
      _logger.info('Server', 'AyuMC Server started successfully');
      _logger.info('Server', '════════════════════════════════════════════');
      _logger.info('Server', '         AyuMC Server - READY              ');
      _logger.info('Server', '════════════════════════════════════════════');
      _logger.info('Server', ' Status: ONLINE');
      _logger.info('Server', ' Protocol: Minecraft Java Edition');
      _logger.info('Server', ' Max Players: 5000+');
      _logger.info('Server', ' Architecture: Multi-threaded');
      _logger.info('Server', '════════════════════════════════════════════');
    } catch (e) {
      state = ServerState.stopped;
      _logger.error('Server', 'Failed to start: $e');
      rethrow;
    }
  }

  static Future<void> stop() async {
    if (state == ServerState.stopped) {
      return;
    }

    state = ServerState.stopping;
    _logger.info('Server', 'Stopping AyuMC Server...');

    await _server.stop();
    state = ServerState.stopped;

    _logger.info('Server', 'AyuMC Server stopped');
  }

  static Future<void> restart() async {
    state = ServerState.restarting;
    _logger.info('Server', 'Restarting AyuMC Server...');

    await stop();
    await Future.delayed(const Duration(milliseconds: 500));
    await start();
  }

  /// Returns comprehensive server statistics.
  static Map<String, dynamic> getStatistics() {
    return _server.getStatistics();
  }

  /// Returns a stream of server log entries.
  static Stream<ServerLogEntry> getLogStream() {
    return _logger.logStream;
  }

  /// Logs a message to the server logger.
  static void log(ServerLogLevel level, String source, String message) {
    switch (level) {
      case ServerLogLevel.debug:
        _logger.debug(source, message);
        break;
      case ServerLogLevel.info:
        _logger.info(source, message);
        break;
      case ServerLogLevel.warning:
        _logger.warning(source, message);
        break;
      case ServerLogLevel.error:
        _logger.error(source, message);
        break;
      case ServerLogLevel.critical:
        _logger.critical(source, message);
        break;
    }
  }
}
