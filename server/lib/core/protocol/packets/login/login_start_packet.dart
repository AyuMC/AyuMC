import 'dart:typed_data';

import '../../packet_reader.dart';

/// Login Start packet sent by the client to initiate login.
///
/// Packet ID: 0x00 (Login state, serverbound)
class LoginStartPacket {
  final String playerName;
  final Uint8List? playerUuid;

  LoginStartPacket({required this.playerName, this.playerUuid});

  /// Parses a Login Start packet from raw data.
  ///
  /// Uses zero-copy parsing where possible to minimize allocations.
  factory LoginStartPacket.parse(Uint8List data) {
    final reader = PacketReader(data);

    // Skip packet length and packet ID (already read)
    reader.readVarInt(); // length
    reader.readVarInt(); // packet ID

    // Read player name
    final playerName = reader.readString();

    // Check if UUID is present (1.19+)
    Uint8List? playerUuid;
    if (reader.hasRemaining) {
      final hasUuid = reader.readBool();
      if (hasUuid) {
        playerUuid = reader.readBytes(16); // UUID is 16 bytes
      }
    }

    return LoginStartPacket(playerName: playerName, playerUuid: playerUuid);
  }

  /// Validates the player name according to Minecraft rules.
  bool isValid() {
    if (playerName.isEmpty || playerName.length > 16) {
      return false;
    }

    // Check for valid characters (alphanumeric and underscore)
    final validPattern = RegExp(r'^[a-zA-Z0-9_]+$');
    return validPattern.hasMatch(playerName);
  }

  @override
  String toString() => 'LoginStartPacket(name: $playerName)';
}
