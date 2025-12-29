import '../entities/server_status.dart';

abstract class ServerRepository {
  Future<void> startServer();
  Future<void> stopServer();
  Future<void> restartServer();
  Stream<ServerStatus> getServerStatus();
}

