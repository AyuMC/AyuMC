import 'dart:async';
import 'package:ayumc_server/server.dart';
import '../../../console/data/repositories/log_repository_impl.dart';
import '../../../console/domain/entities/server_log.dart';
import '../../domain/entities/server_status.dart';
import '../../domain/repositories/server_repository.dart';

class ServerRepositoryImpl implements ServerRepository {
  StreamSubscription? _logSubscription;
  final LogRepositoryImpl _logRepository = LogRepositoryImpl();

  ServerRepositoryImpl() {
    _startLogCapture();
  }

  void _startLogCapture() {
    _logSubscription = AyuMCServer.getLogStream().listen((entry) {
      final log = ServerLog(
        timestamp: entry.timestamp,
        level: _convertLogLevel(entry.level),
        source: entry.source,
        message: entry.message,
      );
      _logRepository.addLog(log);
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

  @override
  Future<void> startServer() async {
    try {
      await AyuMCServer.start();
    } catch (e) {
      throw Exception('Failed to start server: $e');
    }
  }

  @override
  Future<void> stopServer() async {
    try {
      await AyuMCServer.stop();
    } catch (e) {
      throw Exception('Failed to stop server: $e');
    }
  }

  @override
  Future<void> restartServer() async {
    try {
      await AyuMCServer.restart();
    } catch (e) {
      throw Exception('Failed to restart server: $e');
    }
  }

  @override
  Stream<ServerStatus> getServerStatus() async* {
    final state = AyuMCServer.state;

    switch (state) {
      case ServerState.stopped:
        yield const ServerStatus.stopped();
        break;
      case ServerState.starting:
        yield const ServerStatus.starting();
        break;
      case ServerState.running:
        yield const ServerStatus.running();
        break;
      case ServerState.stopping:
        yield const ServerStatus.stopping();
        break;
      case ServerState.restarting:
        yield const ServerStatus.starting();
        break;
    }
  }

  /// Disposes resources.
  void dispose() {
    _logSubscription?.cancel();
  }
}
