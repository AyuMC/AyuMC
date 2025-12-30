import 'dart:typed_data';

import '../../../connection/connection_state.dart';
import '../../packet_reader.dart';

/// Handshake packet sent by the client to initiate a connection.
///
/// Packet ID: 0x00 (Handshake state, serverbound)
class HandshakePacket {
  final int protocolVersion;
  final String serverAddress;
  final int serverPort;
  final ConnectionState nextState;

  HandshakePacket({
    required this.protocolVersion,
    required this.serverAddress,
    required this.serverPort,
    required this.nextState,
  });

  /// Parses a Handshake packet from packet payload data.
  ///
  /// Note: data should be the packet payload AFTER packet length and ID.
  factory HandshakePacket.parse(Uint8List data) {
    final reader = PacketReader(data);

    // Read handshake data directly (no length/ID skipping needed)
    final protocolVersion = reader.readVarInt();
    final serverAddress = reader.readString();
    final serverPort = reader.readUnsignedShort();
    final nextStateId = reader.readVarInt();

    // Map next state ID to ConnectionState
    ConnectionState nextState;
    switch (nextStateId) {
      case 1:
        nextState = ConnectionState.status;
        break;
      case 2:
        nextState = ConnectionState.login;
        break;
      default:
        nextState = ConnectionState.handshake;
    }

    return HandshakePacket(
      protocolVersion: protocolVersion,
      serverAddress: serverAddress,
      serverPort: serverPort,
      nextState: nextState,
    );
  }

  /// Parses from raw packet data including length and ID (for backward compat).
  factory HandshakePacket.parseRaw(Uint8List rawData) {
    final reader = PacketReader(rawData);
    reader.readVarInt(); // Skip packet length
    reader.readVarInt(); // Skip packet ID

    final protocolVersion = reader.readVarInt();
    final serverAddress = reader.readString();
    final serverPort = reader.readUnsignedShort();
    final nextStateId = reader.readVarInt();

    ConnectionState nextState;
    switch (nextStateId) {
      case 1:
        nextState = ConnectionState.status;
        break;
      case 2:
        nextState = ConnectionState.login;
        break;
      default:
        nextState = ConnectionState.handshake;
    }

    return HandshakePacket(
      protocolVersion: protocolVersion,
      serverAddress: serverAddress,
      serverPort: serverPort,
      nextState: nextState,
    );
  }

  @override
  String toString() =>
      'HandshakePacket(protocol: $protocolVersion, address: $serverAddress:$serverPort, nextState: $nextState)';
}
