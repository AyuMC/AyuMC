import 'log_level.dart';
import 'utils/logger_time.dart';

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
    final time = getTime();

    final color = switch (level) {
      LogLevel.info => _green,
      LogLevel.warn => _yellow,
      LogLevel.error => _red,
    };

    final levelName = level.name.toUpperCase();

    print('$color$time [$name] [$levelName] $message$_reset');
  }
}
