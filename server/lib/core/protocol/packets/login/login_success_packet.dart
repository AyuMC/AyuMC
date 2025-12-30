import 'dart:typed_data';
import '../../packet_writer.dart';

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

  /// Serializes the packet payload (without packet ID and length).
  ///
  /// The Packet wrapper will add packet ID and length.
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Write UUID as 16 bytes (2 longs: most significant, least significant)
    writer.writeUuid(uuid);

    // Write username
    writer.writeString(username);

    // Write properties count (we don't support properties yet)
    writer.writeVarInt(propertiesCount);

    return writer.toBytes();
  }

  @override
  String toString() => 'LoginSuccessPacket(uuid: $uuid, name: $username)';
}
