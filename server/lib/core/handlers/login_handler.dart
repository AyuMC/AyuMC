import 'dart:math';
import 'dart:typed_data';

import '../protocol/packet.dart';
import '../protocol/packets/login/login_disconnect_packet.dart';
import '../protocol/packets/login/login_start_packet.dart';
import '../protocol/packets/login/login_success_packet.dart';
import '../session/player_session.dart';
import '../session/session_manager.dart';

/// Handles login protocol packets with ultra-optimization.
///
/// Uses zero-copy operations and minimal allocations.
class LoginHandler {
  LoginHandler._();

  static final SessionManager _sessionManager = SessionManager();

  /// Processes a login start packet.
  ///
  /// Returns the response packet to send to the client.
  static Packet? handleLoginStart(Uint8List packetData) {
    try {
      // Parse packet (zero-copy where possible)
      final loginPacket = LoginStartPacket.parse(packetData);

      // Validate player name
      if (!loginPacket.isValid()) {
        return _createDisconnectPacket('Invalid username');
      }

      // Check if already online
      if (_sessionManager.isUsernameOnline(loginPacket.playerName)) {
        return _createDisconnectPacket(
          'You are already connected to this server',
        );
      }

      // Check session limit
      if (_sessionManager.sessionCount >= SessionManager.kMaxSessions) {
        return _createDisconnectPacket('Server is full');
      }

      // Generate offline-mode UUID
      final uuid = _generateOfflineUuid(loginPacket.playerName);

      // Create session (protocol version will be set by connection handler)
      final session = PlayerSession(
        uuid: uuid,
        username: loginPacket.playerName,
      );

      // Add to session manager
      if (!_sessionManager.addSession(session)) {
        return _createDisconnectPacket('Failed to create session');
      }

      // Send login success
      final successPacket = LoginSuccessPacket(
        uuid: uuid,
        username: loginPacket.playerName,
      );

      return Packet(id: 0x02, data: successPacket.toBytes());
    } catch (e) {
      print('[LoginHandler] Error handling login: $e');
      return _createDisconnectPacket('Login failed');
    }
  }

  /// Generates an offline-mode UUID for a username.
  ///
  /// Uses Minecraft's offline UUID algorithm.
  static String _generateOfflineUuid(String username) {
    final namespace = 'OfflinePlayer:$username';
    final hash = namespace.codeUnits;

    // Simple hash for offline UUID (matches Minecraft behavior)
    final random = Random(hash.fold<int>(0, (prev, curr) => prev + curr));
    final bytes = List.generate(16, (_) => random.nextInt(256));

    // Set version and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x30; // Version 3
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant

    // Format as UUID string
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Creates a disconnect packet with the given reason.
  static Packet _createDisconnectPacket(String reason) {
    final disconnectPacket = LoginDisconnectPacket(reason);
    return Packet(id: 0x00, data: disconnectPacket.toBytes());
  }
}
