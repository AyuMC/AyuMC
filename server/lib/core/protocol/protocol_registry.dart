import 'protocol_version.dart';

/// Protocol-specific packet IDs for different Minecraft versions.
///
/// Ultra-optimized lookup with O(1) access.
class ProtocolRegistry {
  ProtocolRegistry._();

  /// Gets packet IDs for a specific protocol version.
  ///
  /// Returns packet IDs optimized for the given version.
  /// Protocol 769 (1.20.2) uses same packet IDs as 1.20.4.
  static ProtocolPacketIds getPacketIds(int protocolVersion) {
    if (protocolVersion >= ProtocolVersion.v1_21) {
      return ProtocolPacketIds.v1_21();
    } else if (protocolVersion == ProtocolVersion.v1_20_6 ||
        protocolVersion == ProtocolVersion.v1_20_6_alt) {
      // Protocol 769 (1.20.2) uses same packet IDs as 1.20.4
      // Both 766 and 769 are treated as 1.20.6 for packet IDs
      return ProtocolPacketIds.v1_20_6();
    } else if (protocolVersion >= ProtocolVersion.v1_20_4) {
      return ProtocolPacketIds.v1_20_4();
    } else {
      // Fallback to 1.20.4 for older versions (will be expanded)
      return ProtocolPacketIds.v1_20_4();
    }
  }
}

/// Protocol-specific packet IDs for a Minecraft version.
class ProtocolPacketIds {
  final int playJoinGame;
  final int playKeepAliveClientbound;
  final int playKeepAliveServerbound;
  final int playDisconnect;
  final int playPlayerPosition;
  final int playSetDefaultSpawnPosition;
  final int playChunkDataAndLight;
  final int playChunkBatchStart;
  final int playChunkBatchFinished;
  final int playSetCenterChunk;
  final int playPlayerPositionServerbound;
  final int playChatMessage;

  const ProtocolPacketIds({
    required this.playJoinGame,
    required this.playKeepAliveClientbound,
    required this.playKeepAliveServerbound,
    required this.playDisconnect,
    required this.playPlayerPosition,
    required this.playSetDefaultSpawnPosition,
    required this.playChunkDataAndLight,
    required this.playChunkBatchStart,
    required this.playChunkBatchFinished,
    required this.playSetCenterChunk,
    required this.playPlayerPositionServerbound,
    required this.playChatMessage,
  });

  /// Packet IDs for Minecraft 1.20.4 (Protocol 765)
  factory ProtocolPacketIds.v1_20_4() {
    return const ProtocolPacketIds(
      playJoinGame: 0x28,
      playKeepAliveClientbound: 0x23, // Fixed for 1.20.4
      playKeepAliveServerbound: 0x12,
      playDisconnect: 0x1D,
      playPlayerPosition: 0x3E,
      playSetDefaultSpawnPosition: 0x4E,
      playChunkDataAndLight: 0x24, // Fixed for 1.20.4
      playChunkBatchStart: 0x0D,
      playChunkBatchFinished: 0x0E,
      playSetCenterChunk: 0x50,
      playPlayerPositionServerbound: 0x18,
      playChatMessage: 0x06,
    );
  }

  /// Packet IDs for Minecraft 1.20.6 (Protocol 766/769)
  factory ProtocolPacketIds.v1_20_6() {
    return const ProtocolPacketIds(
      playJoinGame: 0x28,
      playKeepAliveClientbound: 0x23, // Same as 1.20.4
      playKeepAliveServerbound: 0x12,
      playDisconnect: 0x1D,
      playPlayerPosition: 0x3E,
      playSetDefaultSpawnPosition: 0x4E,
      playChunkDataAndLight: 0x24, // Same as 1.20.4
      playChunkBatchStart: 0x0D,
      playChunkBatchFinished: 0x0E,
      playSetCenterChunk: 0x50,
      playPlayerPositionServerbound: 0x18,
      playChatMessage: 0x06,
    );
  }

  /// Packet IDs for Minecraft 1.21+ (Protocol 799+)
  factory ProtocolPacketIds.v1_21() {
    return const ProtocolPacketIds(
      playJoinGame: 0x28,
      playKeepAliveClientbound: 0x27,
      playKeepAliveServerbound: 0x18,
      playDisconnect: 0x1D,
      playPlayerPosition: 0x40,
      playSetDefaultSpawnPosition: 0x56,
      playChunkDataAndLight: 0x27,
      playChunkBatchStart: 0x0D,
      playChunkBatchFinished: 0x0E,
      playSetCenterChunk: 0x54,
      playPlayerPositionServerbound: 0x1A,
      playChatMessage: 0x06,
    );
  }
}
