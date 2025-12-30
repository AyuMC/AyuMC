import 'dart:convert';
import 'dart:typed_data';

import '../../packet_writer.dart';
import '../../var_int.dart';

/// Login Disconnect packet sent by the server to disconnect during login.
///
/// Packet ID: 0x00 (Login state, clientbound)
class LoginDisconnectPacket {
  final String reason;

  LoginDisconnectPacket(this.reason);

  /// Serializes the packet to bytes for network transmission.
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Write packet ID
    writer.writeVarInt(0x00);

    // Write reason as JSON chat component
    final jsonReason = jsonEncode({'text': reason});
    writer.writeString(jsonReason);

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
  String toString() => 'LoginDisconnectPacket(reason: $reason)';
}
