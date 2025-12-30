import '../entities/server_log.dart';

/// Repository interface for accessing server logs.
///
/// This abstracts the data source for logs, allowing for different
/// implementations (e.g., from server stream, file, or memory).
abstract class LogRepository {
  /// Returns a stream of logs from the server.
  Stream<ServerLog> getLogStream();

  /// Returns all logs currently in memory.
  List<ServerLog> getAllLogs();

  /// Clears all logs from memory.
  void clearLogs();

  /// Returns logs filtered by level.
  List<ServerLog> getLogsByLevel(LogLevel level);
}
