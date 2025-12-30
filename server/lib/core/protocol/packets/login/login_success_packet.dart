import 'dart:typed_data';

import '../../packet_writer.dart';
import '../../var_int.dart';

/// Login Success packet sent by the server after successful login.
///
/// Packet ID: 0x02 (Login state, clientbound)
class LoginSuccessPacket {
  final String uuid;
  final String username;
  final int propertiesCount;

  LoginSuccessPacket({
    required this.uuid,
    required this.username,
    this.propertiesCount = 0,
  });

  /// Serializes the packet to bytes for network transmission.
  ///
  /// Uses efficient buffer writing to minimize allocations.
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Write packet ID
    writer.writeVarInt(0x02);

    // Write UUID as string
    writer.writeString(uuid);

    // Write username
    writer.writeString(username);

    // Write properties count (we don't support properties yet)
    writer.writeVarInt(propertiesCount);

    // Get the packet data
    final packetData = writer.toBytes();

    // Prepend packet length
    final lengthBytes = VarInt.encode(packetData.length);
    final result = Uint8List(lengthBytes.length + packetData.length);
    result.setRange(0, lengthBytes.length, lengthBytes);
    result.setRange(lengthBytes.length, result.length, packetData);

    return result;
  }

  @override
  String toString() => 'LoginSuccessPacket(uuid: $uuid, name: $username)';
}
