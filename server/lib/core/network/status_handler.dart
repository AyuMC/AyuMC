import 'dart:convert';
import '../protocol/packet.dart';
import '../protocol/packet_reader.dart';
import '../protocol/packet_writer.dart';
import '../../domain/entities/server_status_response.dart';

class StatusHandler {
  StatusHandler._();

  static Packet handleStatusRequest() {
    final response = ServerStatusResponse(
      version: 'AyuMC 1.20.1',
      protocol: 763,
      maxPlayers: 20,
      onlinePlayers: 0,
      description: 'AyuMC Server',
    );

    final writer = PacketWriter();
    writer.writeString(jsonEncode(response.toJson()));

    return Packet(id: 0, data: writer.toBytes());
  }

  static Packet handlePingRequest(PacketReader reader) {
    final payload = reader.readLong();

    final writer = PacketWriter();
    writer.writeLong(payload);

    return Packet(id: 1, data: writer.toBytes());
  }
}
