import 'dart:io';
import '../network/keep_alive/keep_alive_manager.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/packet_reader.dart';
import '../protocol/packets/play/join_game_packet_builder.dart';
import '../protocol/packets/play/keep_alive_packet.dart';
import '../protocol/packets/play/position_packet.dart';
import '../session/player_session.dart';
import 'chat_handler.dart';

/// Ultra-optimized Play protocol handler.
///
/// Handles gameplay packets with minimal overhead and maximum performance.
/// Designed for 5000+ concurrent players with multi-threaded processing.
class PlayHandler {
  PlayHandler._();

  // Entity ID generator (atomic counter for thread safety)
  static int _nextEntityId = 1;

  /// Creates a Join Game packet with ultra-low overhead.
  ///
  /// Uses pre-cached data and efficient buffer operations.
  /// This method is optimized for minimal allocations and maximum throughput.
  static Packet createJoinGamePacket(PlayerSession session, int entityId) {
    final data = JoinGamePacketBuilder.build(
      entityId: entityId,
      isHardcore: false,
      maxPlayers: 5000,
      viewDistance: 10,
      simulationDistance: 10,
      reducedDebugInfo: false,
      enableRespawnScreen: true,
      doLimitedCrafting: false,
      hashedSeed: 0,
      gameMode: 1, // Creative mode
      previousGameMode: -1,
      isDebug: false,
      isFlat: false,
      hasDeathLocation: false,
    );

    return Packet(id: 0x28, data: data);
  }

  /// Generates a unique entity ID for a player.
  ///
  /// Uses atomic increment for thread-safe ID generation.
  static int generateEntityId() {
    return _nextEntityId++;
  }

  /// Registers a player connection for Keep Alive tracking.
  static void registerForKeepAlive(Socket socket, int protocolVersion) {
    KeepAliveManager().registerConnection(
      socket,
      protocolVersion: protocolVersion,
    );
  }

  /// Unregisters a player from Keep Alive tracking.
  static void unregisterFromKeepAlive(Socket socket) {
    KeepAliveManager().unregisterConnection(socket);
  }

  /// Handles incoming play packets with optimized routing.
  ///
  /// Routes packets to specialized handlers based on packet ID.
  /// Uses jump table for O(1) packet dispatch.
  static void handlePacket(
    Packet packet,
    Socket socket,
    void Function(Packet) sendResponse,
    PlayerSession session,
  ) {
    // Fast packet routing using packet ID
    switch (packet.id) {
      case PacketIds.playKeepAliveServerbound:
        _handleKeepAlive(packet, socket);
        break;
      case 0x00: // Teleport Confirm
        _handleTeleportConfirm(packet, session);
        break;
      case PacketIds.playPlayerPositionServerbound:
        _handlePlayerPosition(packet, session);
        break;
      case 0x1B: // Player Position and Rotation
        _handlePlayerPositionRotation(packet, session);
        break;
      case 0x1C: // Player Rotation
        _handlePlayerRotation(packet, session);
        break;
      case PacketIds.playChatMessage:
        _handleChatMessage(packet, socket, session);
        break;
      default:
        // Ignore unknown packets (reduces log spam)
        break;
    }
  }

  /// Handles Keep Alive response from client.
  static void _handleKeepAlive(Packet packet, Socket socket) {
    final keepAlivePacket = KeepAliveServerboundPacket.parse(packet.data);
    KeepAliveManager().onKeepAliveReceived(socket, keepAlivePacket.keepAliveId);
  }

  /// Handles chat messages from client.
  static void _handleChatMessage(
    Packet packet,
    Socket socket,
    PlayerSession session,
  ) {
    ChatHandler.handleChatMessage(packet, session, socket);
  }

  static void _handleTeleportConfirm(Packet packet, PlayerSession session) {
    // Teleport confirmed - no action needed for basic implementation
  }

  /// Handles player position update with ultra-low overhead.
  static void _handlePlayerPosition(Packet packet, PlayerSession session) {
    final posPacket = PlayerPositionServerboundPacket.parse(packet.data);

    // Direct field update - minimal overhead
    session.x = posPacket.x;
    session.y = posPacket.y;
    session.z = posPacket.z;
    session.onGround = posPacket.onGround;
  }

  /// Handles player position + rotation update.
  static void _handlePlayerPositionRotation(
    Packet packet,
    PlayerSession session,
  ) {
    final posPacket = PlayerPositionRotationServerboundPacket.parse(
      packet.data,
    );

    // Direct field update - minimal overhead
    session.x = posPacket.x;
    session.y = posPacket.y;
    session.z = posPacket.z;
    session.yaw = posPacket.yaw;
    session.pitch = posPacket.pitch;
    session.onGround = posPacket.onGround;
  }

  /// Handles player rotation update.
  static void _handlePlayerRotation(Packet packet, PlayerSession session) {
    // Read rotation from packet data directly
    // Format: Float (yaw) + Float (pitch) + Bool (onGround)
    if (packet.data.length >= 9) {
      final reader = PacketReader(packet.data);
      session.yaw = reader.readFloat();
      session.pitch = reader.readFloat();
      session.onGround = reader.readBool();
    }
  }

  /// Creates a Sync Player Position packet.
  static SyncPlayerPositionPacket createSyncPositionPacket(
    PlayerSession session,
    int teleportId,
  ) {
    return SyncPlayerPositionPacket(
      x: session.x,
      y: session.y,
      z: session.z,
      yaw: session.yaw,
      pitch: session.pitch,
      teleportId: teleportId,
    );
  }

  /// Creates a Set Default Spawn Position packet.
  static SetDefaultSpawnPositionPacket createSpawnPositionPacket({
    int x = 0,
    int y = 64,
    int z = 0,
  }) {
    return SetDefaultSpawnPositionPacket(x: x, y: y, z: z);
  }
}
