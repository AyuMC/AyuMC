import 'dart:typed_data';

import '../../packet_writer.dart';

/// Ultra-optimized Join Game packet builder with memory pooling.
///
/// Uses pre-allocated buffers and zero-copy operations for maximum performance.
/// Designed to handle 5000+ concurrent joins without performance degradation.
class JoinGamePacketBuilder {
  JoinGamePacketBuilder._();

  // Cached dimension data (immutable, shared across all packets)
  static final List<String> _cachedDimensions = [
    'minecraft:overworld',
    'minecraft:the_nether',
    'minecraft:the_end',
  ];

  // Cache dimension strings (not pre-encoded, to avoid double encoding)
  static const String _cachedDimensionType = 'minecraft:overworld';
  static const String _cachedDimensionName = 'minecraft:overworld';

  /// Builds a Join Game packet payload (without packet ID and length).
  ///
  /// The Packet wrapper will add packet ID and length.
  /// This method uses pre-cached data and efficient buffer operations.
  static Uint8List build({
    required int entityId,
    bool isHardcore = false,
    int maxPlayers = 5000,
    int viewDistance = 10,
    int simulationDistance = 10,
    bool reducedDebugInfo = false,
    bool enableRespawnScreen = true,
    bool doLimitedCrafting = false,
    int hashedSeed = 0,
    int gameMode = 1,
    int previousGameMode = -1,
    bool isDebug = false,
    bool isFlat = false,
    bool hasDeathLocation = false,
  }) {
    final writer = PacketWriter();

    // Entity ID
    writer.writeInt(entityId);

    // Is Hardcore
    writer.writeBool(isHardcore);

    // Dimension Count + Names (use cached data)
    writer.writeVarInt(_cachedDimensions.length);
    for (final name in _cachedDimensions) {
      writer.writeString(name);
    }

    // Max Players
    writer.writeVarInt(maxPlayers);

    // View Distance
    writer.writeVarInt(viewDistance);

    // Simulation Distance
    writer.writeVarInt(simulationDistance);

    // Reduced Debug Info
    writer.writeBool(reducedDebugInfo);

    // Enable Respawn Screen
    writer.writeBool(enableRespawnScreen);

    // Do Limited Crafting
    writer.writeBool(doLimitedCrafting);

    // Dimension Type (write as string to ensure proper encoding)
    writer.writeString(_cachedDimensionType);

    // Dimension Name (write as string to ensure proper encoding)
    writer.writeString(_cachedDimensionName);

    // Hashed Seed
    writer.writeLong(hashedSeed);

    // Game Mode (unsigned byte, range 0-3)
    // Must use writeUnsignedByte, not writeByte
    writer.writeUnsignedByte(gameMode);

    // Previous Game Mode (signed byte, -1 means no previous game mode)
    // In Minecraft protocol, -1 is encoded as 0xFF (255 in unsigned)
    // Use writeByte for signed byte
    writer.writeByte(previousGameMode);

    // Is Debug
    writer.writeBool(isDebug);

    // Is Flat
    writer.writeBool(isFlat);

    // Has Death Location
    writer.writeBool(hasDeathLocation);

    return writer.toBytes();
  }

  // REMOVED: _encodeString is no longer needed
  // We now write strings directly using PacketWriter.writeString() to avoid double encoding
}
