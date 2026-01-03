import 'dart:typed_data';
import '../../packet_writer.dart';

/// Player Info Update packet (Clientbound).
///
/// Sent by server to add/update player information in tab list.
/// REQUIRED after Join Game in Minecraft 1.19+.
class PlayerInfoUpdatePacket {
  final List<PlayerInfoAction> actions;
  final List<PlayerInfoEntry> entries;

  const PlayerInfoUpdatePacket({
    required this.actions,
    required this.entries,
  });

  /// Builds the packet payload (without packet ID and length).
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Actions bitmask
    int actionsMask = 0;
    for (final action in actions) {
      actionsMask |= action.bitMask;
    }
    writer.writeVarInt(actionsMask);

    // Number of entries
    writer.writeVarInt(entries.length);

    // Write each entry
    for (final entry in entries) {
      // UUID (16 bytes)
      writer.writeUuid(entry.uuid);

      // Write data for each action
      for (final action in actions) {
        switch (action) {
          case PlayerInfoAction.addPlayer:
            // Name
            writer.writeString(entry.name);
            // Properties (empty for now)
            writer.writeVarInt(0);
            break;

          case PlayerInfoAction.updateGameMode:
            // Game mode
            writer.writeVarInt(entry.gameMode);
            break;

          case PlayerInfoAction.updateListed:
            // Listed (bool)
            writer.writeBool(entry.listed);
            break;

          case PlayerInfoAction.updateLatency:
            // Latency (VarInt, in milliseconds)
            writer.writeVarInt(entry.latency);
            break;

          case PlayerInfoAction.updateDisplayName:
            // Display name (optional, null for now)
            writer.writeBool(false); // Has display name = false
            break;

          default:
            // Unknown action - skip
            break;
        }
      }
    }

    return writer.toBytes();
  }
}

/// Player Info Action types.
enum PlayerInfoAction {
  addPlayer(0x01),
  initializeChat(0x02),
  updateGameMode(0x04),
  updateListed(0x08),
  updateLatency(0x10),
  updateDisplayName(0x20);

  final int bitMask;
  const PlayerInfoAction(this.bitMask);
}

/// Player Info Entry data.
class PlayerInfoEntry {
  final String uuid;
  final String name;
  final int gameMode;
  final bool listed;
  final int latency;

  const PlayerInfoEntry({
    required this.uuid,
    required this.name,
    this.gameMode = 1, // Creative
    this.listed = true,
    this.latency = 0,
  });
}

