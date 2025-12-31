import 'dart:convert';
import 'dart:io';
import '../logging/server_logger.dart';
import '../protocol/packet.dart';
import '../protocol/packet_reader.dart';
import '../protocol/packet_writer.dart';
import '../../domain/entities/server_status_response.dart';
import '../session/session_manager.dart';

/// Handles status protocol packets (server list ping).
class StatusHandler {
  StatusHandler._();

  static final ServerLogger _logger = ServerLogger();

  /// Handles status request (server list query).
  ///
  /// Returns server information including version, players, and description.
  static Packet handleStatusRequest({Socket? socket}) {
    final sessionManager = SessionManager();
    final onlineCount = sessionManager.sessionCount;

    final response = ServerStatusResponse(
      version: 'AyuMC 1.20.4',
      protocol: 765,
      maxPlayers: 5000,
      onlinePlayers: onlineCount,
      description: 'AyuMC High-Performance Server',
    );

    final writer = PacketWriter();
    writer.writeString(jsonEncode(response.toJson()));

    if (socket != null) {
      final clientInfo = '${socket.remoteAddress.address}:${socket.remotePort}';
      _logger.debug(
        'StatusHandler',
        'Status request from $clientInfo (Online: $onlineCount/5000)',
      );
    }

    return Packet(id: 0, data: writer.toBytes());
  }

  /// Handles ping request (latency test).
  ///
  /// Echoes the payload back to measure round-trip time.
  static Packet handlePingRequest(PacketReader reader, {Socket? socket}) {
    final payload = reader.readLong();
    final startTime = DateTime.now();

    final writer = PacketWriter();
    writer.writeLong(payload);

    if (socket != null) {
      final clientInfo = '${socket.remoteAddress.address}:${socket.remotePort}';
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      _logger.info(
        'StatusHandler',
        'Ping from $clientInfo (Latency: ${latency}ms)',
      );
    }

    return Packet(id: 1, data: writer.toBytes());
  }
}
