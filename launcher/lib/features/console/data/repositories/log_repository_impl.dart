import 'dart:async';
import 'package:ayumc_server/server.dart';
import '../../domain/entities/server_log.dart';
import '../../domain/repositories/log_repository.dart';

/// Implementation of LogRepository that captures server logs.
///
/// This implementation maintains an in-memory buffer of logs and provides
/// a stream for real-time log updates.
class LogRepositoryImpl implements LogRepository {
  static final LogRepositoryImpl _instance = LogRepositoryImpl._internal();
  factory LogRepositoryImpl() => _instance;

  LogRepositoryImpl._internal() {
    // Lazy initialization: seed and capture will happen when first accessed
    // This ensures server is ready before we try to get logs
  }

  /// Ensures the repository is initialized and ready.
  void _ensureInitialized() {
    if (!_seeded) {
      _seedFromServerHistory();
      _startLogCapture();
    }
  }

  final StreamController<ServerLog> _logController =
      StreamController.broadcast();
  final List<ServerLog> _logs = [];
  StreamSubscription? _serverLogSubscription;
  bool _seeded = false;

  static const int kMaxLogsInMemory = 10000;

  void _seedFromServerHistory() {
    if (_seeded) return;
    _seeded = true;

    final history = AyuMCServer.getAllLogs();
    for (final entry in history) {
      _addToMemory(
        ServerLog(
          timestamp: entry.timestamp,
          level: _convertLogLevel(entry.level),
          source: entry.source,
          message: entry.message,
        ),
      );
    }
  }

  /// Starts capturing logs directly from the server.
  void _startLogCapture() {
    _serverLogSubscription = AyuMCServer.getLogStream().listen((entry) {
      final log = ServerLog(
        timestamp: entry.timestamp,
        level: _convertLogLevel(entry.level),
        source: entry.source,
        message: entry.message,
      );
      addLog(log);
    });
  }

  LogLevel _convertLogLevel(ServerLogLevel serverLevel) {
    return switch (serverLevel) {
      ServerLogLevel.debug => LogLevel.debug,
      ServerLogLevel.info => LogLevel.info,
      ServerLogLevel.warning => LogLevel.warning,
      ServerLogLevel.error => LogLevel.error,
      ServerLogLevel.critical => LogLevel.critical,
    };
  }

  /// Adds a new log entry.
  ///
  /// This is called internally when the server produces a log message.
  void addLog(ServerLog log) {
    // Avoid rare boundary duplicates (history seed + stream)
    if (_logs.isNotEmpty) {
      final last = _logs.last;
      final isDuplicate =
          last.timestamp == log.timestamp &&
          last.level == log.level &&
          last.source == log.source &&
          last.message == log.message;
      if (isDuplicate) return;
    }

    _addToMemory(log);
    _logController.add(log);
  }

  void _addToMemory(ServerLog log) {
    _logs.add(log);

    // Keep memory usage bounded
    if (_logs.length > kMaxLogsInMemory) {
      _logs.removeAt(0);
    }
  }

  @override
  Stream<ServerLog> getLogStream() {
    _ensureInitialized();
    return _logController.stream;
  }

  @override
  List<ServerLog> getAllLogs() {
    _ensureInitialized();
    // Re-seed to ensure we have all logs (in case server started after repository creation)
    _seedFromServerHistory();
    return List.unmodifiable(_logs);
  }

  @override
  List<ServerLog> getLogsByLevel(LogLevel level) {
    return _logs.where((log) => log.level == level).toList();
  }

  /// Disposes resources.
  void dispose() {
    _serverLogSubscription?.cancel();
    _logController.close();
  }
}
