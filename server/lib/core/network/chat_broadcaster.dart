import 'dart:io';

import '../logging/server_logger.dart';
import '../protocol/packets/play/chat_packet.dart';

/// Ultra-optimized chat broadcasting system.
///
/// Manages socket references for efficient message broadcasting.
class ChatBroadcaster {
  static const String _tag = 'ChatBroadcaster';
  static final ServerLogger _logger = ServerLogger();

  /// Map of player UUID -> Socket for broadcasting
  static final Map<String, Socket> _playerSockets = {};

  /// Registers a player's socket for chat broadcasting.
  static void registerPlayer(String uuid, Socket socket) {
    _playerSockets[uuid] = socket;
  }

  /// Unregisters a player's socket.
  static void unregisterPlayer(String uuid) {
    _playerSockets.remove(uuid);
  }

  /// Broadcasts a chat message to all online players.
  ///
  /// Ultra-optimized: pre-builds packet once and sends to all.
  static void broadcastChatMessage(
    String sender,
    String message,
    int protocolVersion,
  ) {
    if (_playerSockets.isEmpty) return;

    // Pre-build packet once for all players
    final chatPacket = PlayerChatMessagePacket(
      sender: sender,
      message: message,
      timestamp: DateTime.now(),
      protocolVersion: protocolVersion,
    );

    final packetBytes = chatPacket.toFramedBytes();
    int sentCount = 0;
    final failedSockets = <String>[];

    for (final entry in _playerSockets.entries) {
      try {
        entry.value.add(packetBytes);
        sentCount++;
      } catch (e) {
        _logger.warning(_tag, 'Failed to send chat to player ${entry.key}: $e');
        failedSockets.add(entry.key);
      }
    }

    // Clean up failed sockets
    for (final uuid in failedSockets) {
      _playerSockets.remove(uuid);
    }

    if (sentCount > 0) {
      _logger.debug(_tag, 'Broadcasted chat to $sentCount players');
    }
  }

  /// Sends a system message to a specific player.
  static void sendSystemMessage(
    String playerUuid,
    String message, {
    int protocolVersion = 765,
  }) {
    final socket = _playerSockets[playerUuid];
    if (socket == null) return;

    try {
      final systemPacket = SystemChatMessagePacket(
        message: message,
        protocolVersion: protocolVersion,
      );
      socket.add(systemPacket.toFramedBytes());
    } catch (e) {
      _logger.error(_tag, 'Error sending system message: $e');
      _playerSockets.remove(playerUuid);
    }
  }

  /// Broadcasts a system message to all players.
  static void broadcastSystemMessage(
    String message, {
    int protocolVersion = 765,
  }) {
    if (_playerSockets.isEmpty) return;

    final systemPacket = SystemChatMessagePacket(
      message: message,
      protocolVersion: protocolVersion,
    );

    final packetBytes = systemPacket.toFramedBytes();
    int sentCount = 0;
    final failedSockets = <String>[];

    for (final entry in _playerSockets.entries) {
      try {
        entry.value.add(packetBytes);
        sentCount++;
      } catch (e) {
        failedSockets.add(entry.key);
      }
    }

    for (final uuid in failedSockets) {
      _playerSockets.remove(uuid);
    }

    _logger.info(_tag, 'Broadcasted system message to $sentCount players');
  }

  /// Returns the number of registered players.
  static int get playerCount => _playerSockets.length;

  /// Clears all registered sockets (for shutdown).
  static void clear() {
    _playerSockets.clear();
  }
}
