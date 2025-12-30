import 'package:equatable/equatable.dart';

/// Represents the severity level of a log message.
enum LogLevel { debug, info, warning, error, critical }

/// Extension methods for LogLevel styling.
extension LogLevelExtensions on LogLevel {
  /// Returns a color representation for this log level.
  int get color {
    switch (this) {
      case LogLevel.debug:
        return 0xFF6C757D; // Gray
      case LogLevel.info:
        return 0xFF0D6EFD; // Blue
      case LogLevel.warning:
        return 0xFFFFC107; // Yellow
      case LogLevel.error:
        return 0xFFDC3545; // Red
      case LogLevel.critical:
        return 0xFF6F1E51; // Dark Red
    }
  }

  /// Returns a prefix string for this log level.
  String get prefix {
    switch (this) {
      case LogLevel.debug:
        return '[DEBUG]';
      case LogLevel.info:
        return '[INFO]';
      case LogLevel.warning:
        return '[WARN]';
      case LogLevel.error:
        return '[ERROR]';
      case LogLevel.critical:
        return '[CRITICAL]';
    }
  }
}

/// Represents a single log entry from the server.
class ServerLog extends Equatable {
  final DateTime timestamp;
  final LogLevel level;
  final String source;
  final String message;

  const ServerLog({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  @override
  List<Object?> get props => [timestamp, level, source, message];

  /// Creates a formatted string representation of this log.
  String toFormattedString() {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    return '$time ${level.prefix} [$source] $message';
  }
}
