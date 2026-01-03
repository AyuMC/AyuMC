import 'dart:io';
import '../logging/server_logger.dart';
import '../network/keep_alive/keep_alive_manager.dart';
import '../protocol/packet.dart';
import '../protocol/packet_reader.dart';
import '../protocol/protocol_registry.dart';
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
    final packetIds = ProtocolRegistry.getPacketIds(session.protocolVersion);
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

    return Packet(id: packetIds.playJoinGame, data: data);
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

  /// Callback for sending chunks after teleport confirm (set by connection handler)
  static void Function(PlayerSession)? onTeleportConfirmed;

  /// Handles incoming play packets with optimized routing.
  ///
  /// Routes packets to specialized handlers based on packet ID.
  /// Uses protocol-aware packet ID lookup for version compatibility.
  static void handlePacket(
    Packet packet,
    Socket socket,
    void Function(Packet) sendResponse,
    PlayerSession session,
  ) {
    // Get protocol-specific packet IDs
    final packetIds = ProtocolRegistry.getPacketIds(session.protocolVersion);
    final packetId = packet.id;

    // Fast packet routing using protocol-aware packet IDs
    if (packetId == packetIds.playKeepAliveServerbound) {
      _handleKeepAlive(packet, socket);
    } else if (packetId == 0x00) {
      // Teleport Confirm (same across versions)
      _handleTeleportConfirm(packet, session);
    } else if (packetId == 0x01) {
      // Query Block Entity Tag (1.20.4+)
      _handleQueryBlockEntityTag(packet, session);
    } else if (packetId == 0x03) {
      // Client Command (1.20.4) - different from 0x07 in newer versions
      _handleClientCommand(packet, session);
    } else if (packetId == packetIds.playPlayerPositionServerbound) {
      _handlePlayerPosition(packet, session);
    } else if (packetId == 0x1B || packetId == 0x1C) {
      // Player Position and Rotation (version-dependent)
      _handlePlayerPositionRotation(packet, session);
    } else if (packetId == 0x1C || packetId == 0x1D) {
      // Player Rotation (version-dependent)
      _handlePlayerRotation(packet, session);
    } else if (packetId == packetIds.playChatMessage) {
      _handleChatMessage(packet, socket, session);
    } else if (packetId == 0x28) {
      // Configuration Acknowledged (1.20.2+)
      _handleConfigurationAcknowledged(packet, session);
    } else if (packetId == 0x05) {
      // Client Information (1.20.2+)
      _handleClientInformation(packet, session);
    } else if (packetId == 0x07) {
      // Client Command (1.20.2+)
      _handleClientCommand(packet, session);
    } else {
      // Log unknown packets for debugging (only first occurrence)
      _logUnknownPacket(packetId, session.protocolVersion);
    }
  }

  /// Handles Configuration Acknowledged packet (1.20.2+).
  static void _handleConfigurationAcknowledged(
    Packet packet,
    PlayerSession session,
  ) {
    // Client acknowledges configuration - no action needed
    // This packet is sent after client receives configuration packets
  }

  /// Handles Client Information packet (1.20.2+).
  static void _handleClientInformation(Packet packet, PlayerSession session) {
    // Client sends information like language, view distance, etc.
    // For now, we just acknowledge it
    try {
      final reader = PacketReader(packet.data);
      reader.readString(); // locale
      reader.readByte(); // viewDistance
      reader.readVarInt(); // chatMode
      reader.readBool(); // chatColors
      reader.readUnsignedByte(); // displayedSkinParts
      reader.readVarInt(); // mainHand
      reader.readBool(); // enableTextFiltering
      reader.readBool(); // allowServerListings

      // Store client preferences in session (if needed)
      // For now, we just acknowledge
    } catch (e) {
      // Ignore parsing errors for optional packets
    }
  }

  /// Handles Client Command packet (1.20.2+).
  static void _handleClientCommand(Packet packet, PlayerSession session) {
    // Client sends command acknowledgment
    // For now, we just acknowledge it
    try {
      final reader = PacketReader(packet.data);
      reader.readVarInt(); // actionId: 0 = perform respawn, 1 = request stats
      // For now, we just acknowledge
    } catch (e) {
      // Ignore parsing errors for optional packets
    }
  }

  /// Logs unknown packet for debugging (only once per packet ID).
  static final Set<int> _loggedUnknownPackets = {};

  static void _logUnknownPacket(int packetId, int protocolVersion) {
    if (!_loggedUnknownPackets.contains(packetId)) {
      _loggedUnknownPackets.add(packetId);
      // Use ServerLogger instead of print
      final logger = ServerLogger();
      logger.debug(
        'PlayHandler',
        'Unknown packet ID: 0x${packetId.toRadixString(16).toUpperCase().padLeft(2, '0')} (Protocol: $protocolVersion)',
      );
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
    // CRITICAL: Client confirmed teleport - now we can send chunks!
    try {
      final reader = PacketReader(packet.data);
      final teleportId = reader.readVarInt();
      
      // Confirm the teleport
      session.confirmTeleport(teleportId);
      
      // Notify connection handler to send chunks
      if (onTeleportConfirmed != null) {
        onTeleportConfirmed!(session);
      }
    } catch (e) {
      // Log error but don't crash
      final logger = ServerLogger();
      logger.warning('PlayHandler', 'Error handling teleport confirm: $e');
    }
  }

  /// Handles Query Block Entity Tag packet (1.20.4+).
  ///
  /// Client queries block entity data (e.g., chest contents, sign text).
  /// For now, we just acknowledge it without sending response.
  static void _handleQueryBlockEntityTag(Packet packet, PlayerSession session) {
    // Client queries block entity tag - no action needed for basic implementation
    // In full implementation, we would parse the query and send response
    try {
      final reader = PacketReader(packet.data);
      reader.readPosition(); // Read block position
      // Query is acknowledged silently
    } catch (e) {
      // Ignore parsing errors for optional packets
    }
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
      protocolVersion: session.protocolVersion,
    );
  }

  /// Creates a Set Default Spawn Position packet.
  static SetDefaultSpawnPositionPacket createSpawnPositionPacket({
    int x = 0,
    int y = 64,
    int z = 0,
    int protocolVersion = 765,
  }) {
    return SetDefaultSpawnPositionPacket(
      x: x,
      y: y,
      z: z,
      protocolVersion: protocolVersion,
    );
  }
}
