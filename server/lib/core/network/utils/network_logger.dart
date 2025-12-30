import '../../logging/server_logger.dart';

/// Utility for network logging with automatic routing to ServerLogger.
class NetworkLogger {
  NetworkLogger._();

  static final ServerLogger _logger = ServerLogger();

  static void info(String source, String message) {
    _logger.info(source, message);
  }

  static void debug(String source, String message) {
    _logger.debug(source, message);
  }

  static void warning(String source, String message) {
    _logger.warning(source, message);
  }

  static void error(String source, String message) {
    _logger.error(source, message);
  }
}
