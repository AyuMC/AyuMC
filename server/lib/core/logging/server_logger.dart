import 'dart:async';

/// Log level enumeration.
enum ServerLogLevel { debug, info, warning, error, critical }

/// A single log entry.
class ServerLogEntry {
  final DateTime timestamp;
  final ServerLogLevel level;
  final String source;
  final String message;

  ServerLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  @override
  String toString() {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    return '$time [${level.name.toUpperCase()}] [$source] $message';
  }
}

/// Server-side logger with broadcast stream support.
///
/// Captures all server logs and broadcasts them to listeners (e.g., Launcher UI).
class ServerLogger {
  static final ServerLogger _instance = ServerLogger._internal();
  factory ServerLogger() => _instance;
  ServerLogger._internal();

  final StreamController<ServerLogEntry> _logController =
      StreamController.broadcast();

  /// Returns a stream of log entries.
  Stream<ServerLogEntry> get logStream => _logController.stream;

  /// Logs a debug message.
  void debug(String source, String message) {
    _log(ServerLogLevel.debug, source, message);
  }

  /// Logs an info message.
  void info(String source, String message) {
    _log(ServerLogLevel.info, source, message);
  }

  /// Logs a warning message.
  void warning(String source, String message) {
    _log(ServerLogLevel.warning, source, message);
  }

  /// Logs an error message.
  void error(String source, String message) {
    _log(ServerLogLevel.error, source, message);
  }

  /// Logs a critical message.
  void critical(String source, String message) {
    _log(ServerLogLevel.critical, source, message);
  }

  void _log(ServerLogLevel level, String source, String message) {
    final entry = ServerLogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
    );

    // Print to console
    print(entry.toString());

    // Broadcast to listeners
    _logController.add(entry);
  }

  /// Closes the log stream.
  void close() {
    _logController.close();
  }
}
