import 'dart:typed_data';
import '../../packet_writer.dart';
import '../../var_int.dart';

/// Join Game packet sent by the server when a player joins.
///
/// Packet ID: 0x28 (Play state, clientbound) for 1.21+
class JoinGamePacket {
  final int entityId;
  final bool isHardcore;
  final List<String> dimensionNames;
  final int maxPlayers;
  final int viewDistance;
  final int simulationDistance;
  final bool reducedDebugInfo;
  final bool enableRespawnScreen;
  final bool doLimitedCrafting;
  final String dimensionType;
  final String dimensionName;
  final int hashedSeed;
  final int gameMode;
  final int previousGameMode;
  final bool isDebug;
  final bool isFlat;
  final bool hasDeathLocation;

  JoinGamePacket({
    required this.entityId,
    this.isHardcore = false,
    required this.dimensionNames,
    required this.maxPlayers,
    this.viewDistance = 10,
    this.simulationDistance = 10,
    this.reducedDebugInfo = false,
    this.enableRespawnScreen = true,
    this.doLimitedCrafting = false,
    required this.dimensionType,
    required this.dimensionName,
    required this.hashedSeed,
    required this.gameMode,
    this.previousGameMode = -1,
    this.isDebug = false,
    this.isFlat = false,
    this.hasDeathLocation = false,
  });

  /// Serializes the packet to bytes for network transmission.
  Uint8List toBytes() {
    final writer = PacketWriter();

    // Write packet ID (0x28 for Join Game in 1.21+)
    writer.writeVarInt(0x28);

    // Entity ID (player's entity ID)
    writer.writeInt(entityId);

    // Is Hardcore
    writer.writeBool(isHardcore);

    // Dimension Count + Names
    writer.writeVarInt(dimensionNames.length);
    for (final name in dimensionNames) {
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

    // Dimension Type
    writer.writeString(dimensionType);

    // Dimension Name
    writer.writeString(dimensionName);

    // Hashed Seed
    writer.writeLong(hashedSeed);

    // Game Mode
    writer.writeByte(gameMode);

    // Previous Game Mode
    writer.writeByte(previousGameMode);

    // Is Debug
    writer.writeBool(isDebug);

    // Is Flat
    writer.writeBool(isFlat);

    // Has Death Location
    writer.writeBool(hasDeathLocation);

    // Get packet data
    final packetData = writer.toBytes();

    // Prepend packet length
    final lengthBytes = VarInt.encode(packetData.length);
    final result = Uint8List(lengthBytes.length + packetData.length);
    result.setRange(0, lengthBytes.length, lengthBytes);
    result.setRange(lengthBytes.length, result.length, packetData);

    return result;
  }

  @override
  String toString() =>
      'JoinGamePacket(entityId: $entityId, gameMode: $gameMode)';
}
