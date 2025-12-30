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

  /// Parses a Handshake packet from raw data.
  factory HandshakePacket.parse(Uint8List data) {
    final reader = PacketReader(data);

    // Skip packet length and packet ID
    reader.readVarInt(); // length
    reader.readVarInt(); // packet ID

    // Read handshake data
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

  @override
  String toString() =>
      'HandshakePacket(protocol: $protocolVersion, address: $serverAddress:$serverPort, nextState: $nextState)';
}
