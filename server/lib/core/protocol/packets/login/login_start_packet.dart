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
  /// Note: data should be the packet payload AFTER packet ID has been read.
  factory LoginStartPacket.parse(Uint8List data) {
    final reader = PacketReader(data);

    // Read player name (first field in Login Start packet)
    final playerName = reader.readString();

    // For Minecraft 1.19+, there's an optional UUID
    // For versions before 1.19, there's no UUID field
    Uint8List? playerUuid;
    if (reader.hasRemaining) {
      // In 1.19+, there's a boolean indicating if UUID is present
      try {
        final hasUuid = reader.readBool();
        if (hasUuid && reader.hasRemaining) {
          playerUuid = reader.readBytes(16); // UUID is 16 bytes
        }
      } catch (e) {
        // If reading UUID fails, just ignore it (backward compatibility)
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
