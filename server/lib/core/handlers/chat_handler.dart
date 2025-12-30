import 'dart:io';
import '../logging/server_logger.dart';
import '../network/chat_broadcaster.dart';
import '../protocol/packet.dart';
import '../protocol/packets/play/chat_packet.dart';
import '../session/player_session.dart';

/// Ultra-optimized Chat protocol handler.
///
/// Handles chat messages with minimal overhead and efficient broadcasting.
class ChatHandler {
  ChatHandler._();

  static final ServerLogger _logger = ServerLogger();
  static const String _tag = 'ChatHandler';

  /// Processes an incoming chat message from a player.
  ///
  /// Returns true if the message was processed successfully.
  static bool handleChatMessage(
    Packet packet,
    PlayerSession session,
    Socket socket,
  ) {
    try {
      final chatPacket = ChatMessageServerboundPacket.parse(packet.data);
      final message = chatPacket.message.trim();

      // Validate message
      if (message.isEmpty) {
        return false;
      }

      if (message.length > 256) {
        _logger.warning(
          _tag,
          'Player ${session.username} sent message too long (${message.length} chars)',
        );
        return false;
      }

      // Log chat message
      _logger.info(_tag, '<${session.username}> $message');

      // Broadcast to all players
      ChatBroadcaster.broadcastChatMessage(
        session.username,
        message,
        session.protocolVersion,
      );

      return true;
    } catch (e) {
      _logger.error(_tag, 'Error handling chat message: $e');
      return false;
    }
  }
}
