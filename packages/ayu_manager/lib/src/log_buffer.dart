import 'package:ayu_logging/ayu_logging.dart';

/// Bounded in-memory history. Dropping a line here does not delete the copy already printed or stored elsewhere.
final class LogBuffer {
  LogBuffer({this.capacity = 400});

  final int capacity;
  final List<LogRecord> _lines = [];
  int dropped = 0;

  List<LogRecord> get lines => List.unmodifiable(_lines);

  void add(LogRecord record) {
    _lines.add(record);
    if (_lines.length > capacity) {
      _lines.removeAt(0);
      dropped++;
    }
  }

  List<LogRecord> filtered({LogLevel? minimum, String query = ''}) {
    final needle = query.toLowerCase();
    return [
      for (final line in _lines)
        if ((minimum == null || line.level.index >= minimum.index) &&
            (needle.isEmpty ||
                '${line.loggerName} ${line.message}'.toLowerCase().contains(
                  needle,
                )))
          line,
    ];
  }
}
