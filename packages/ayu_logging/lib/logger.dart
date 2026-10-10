import 'log_level.dart';
import 'utils/logger_time.dart';

/// One structured log line. The terminal manager listens for these; the
/// headless server still prints them.
final class LogRecord {
  LogRecord({required this.time, required this.loggerName, required this.level, required this.message});

  final DateTime time;
  final String loggerName;
  final LogLevel level;
  final String message;
}

/// Fan-out for log lines. Listeners must be fast; a slow UI keeps its own buffer.
abstract final class LogHub {
  static final List<void Function(LogRecord record)> listeners = [];

  /// When false, lines are only delivered to [listeners]. Headless mode leaves this true.
  static bool echo = true;

  static void emit(LogRecord record) {
    for (final listener in List.of(listeners)) {
      listener(record);
    }
  }
}

class Logger {
  final String name;

  Logger(this.name);

  static const _reset = '\x1B[0m';
  static const _green = '\x1B[32m';
  static const _yellow = '\x1B[33m';
  static const _red = '\x1B[31m';

  void info(String message) {
    _log(LogLevel.info, message);
  }

  void warn(String message) {
    _log(LogLevel.warn, message);
  }

  void error(String message) {
    _log(LogLevel.error, message);
  }

  void _log(LogLevel level, String message) {
    final record = LogRecord(time: DateTime.now(), loggerName: name, level: level, message: message);
    LogHub.emit(record);
    if (!LogHub.echo) return;

    final time = getTime();
    final color = switch (level) {
      LogLevel.info => _green,
      LogLevel.warn => _yellow,
      LogLevel.error => _red,
    };
    print('$color$time [$name] [${level.name.toUpperCase()}] $message$_reset');
  }
}
