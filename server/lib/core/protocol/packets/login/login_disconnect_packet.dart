import 'dart:convert';
import 'dart:typed_data';
import '../../packet_writer.dart';

/// Login Disconnect packet sent by the server to disconnect during login.
///
/// Packet ID: 0x00 (Login state, clientbound)
class LoginDisconnectPacket {
  final String reason;

  LoginDisconnectPacket(this.reason);

  /// Serializes the packet payload (without packet ID and length).
  ///
  /// The Packet wrapper will add packet ID and length.
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Write reason as JSON chat component
    final jsonReason = jsonEncode({'text': reason});
    writer.writeString(jsonReason);

    return writer.toBytes();
  }

  @override
  String toString() => 'LoginDisconnectPacket(reason: $reason)';
}
