import 'dart:async';
import '../../domain/entities/server_log.dart';
import '../../domain/repositories/log_repository.dart';

/// Implementation of LogRepository that captures server logs.
///
/// This implementation maintains an in-memory buffer of logs and provides
/// a stream for real-time log updates.
class LogRepositoryImpl implements LogRepository {
  static final LogRepositoryImpl _instance = LogRepositoryImpl._internal();
  factory LogRepositoryImpl() => _instance;
  LogRepositoryImpl._internal();

  final StreamController<ServerLog> _logController =
      StreamController.broadcast();
  final List<ServerLog> _logs = [];

  static const int kMaxLogsInMemory = 10000;

  /// Adds a new log entry.
  ///
  /// This is called internally when the server produces a log message.
  void addLog(ServerLog log) {
    _logs.add(log);
    _logController.add(log);

    // Keep memory usage bounded
    if (_logs.length > kMaxLogsInMemory) {
      _logs.removeAt(0);
    }
  }

  @override
  Stream<ServerLog> getLogStream() {
    return _logController.stream;
  }

  @override
  List<ServerLog> getAllLogs() {
    return List.unmodifiable(_logs);
  }

  @override
  void clearLogs() {
    _logs.clear();
  }

  @override
  List<ServerLog> getLogsByLevel(LogLevel level) {
    return _logs.where((log) => log.level == level).toList();
  }

  /// Disposes resources.
  void dispose() {
    _logController.close();
  }
}
