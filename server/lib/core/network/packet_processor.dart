import 'dart:io';

import '../connection/connection_state.dart';
import '../handlers/login_handler.dart';
import '../handlers/play_handler.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/packet_reader.dart';
import '../session/player_session.dart';
import 'status_handler.dart';

/// Processes incoming packets and routes them to appropriate handlers.
///
/// Uses efficient routing based on connection state for minimal overhead.
class PacketProcessor {
  PacketProcessor._();

  /// Processes a packet based on the connection state.
  ///
  /// [packet]: The packet to process
  /// [sendResponse]: Callback to send response packets
  /// [state]: Current connection state (defaults to status for backward compatibility)
  /// [socket]: Optional socket for logging client information
  static void process(
    Packet packet,
    void Function(Packet) sendResponse, {
    ConnectionState state = ConnectionState.status,
    Socket? socket,
  }) {
    switch (state) {
      case ConnectionState.status:
        _processStatusPacket(packet, sendResponse, socket: socket);
        break;
      case ConnectionState.login:
        _processLoginPacket(packet, sendResponse);
        break;
      case ConnectionState.play:
        _processPlayPacket(packet, sendResponse);
        break;
      default:
        // Ignore unknown states silently
        break;
    }
  }

  /// Processes status packets (server list ping).
  static void _processStatusPacket(
    Packet packet,
    void Function(Packet) sendResponse, {
    Socket? socket,
  }) {
    switch (packet.id) {
      case PacketIds.statusRequest:
        final response = StatusHandler.handleStatusRequest(socket: socket);
        sendResponse(response);
        break;
      case PacketIds.statusPing:
        final reader = PacketReader(packet.data);
        final response = StatusHandler.handlePingRequest(
          reader,
          socket: socket,
        );
        sendResponse(response);
        break;
      default:
        // Ignore unknown packets silently
        break;
    }
  }

  /// Processes login packets.
  static void _processLoginPacket(
    Packet packet,
    void Function(Packet) sendResponse,
  ) {
    switch (packet.id) {
      case PacketIds.loginStart:
        final response = LoginHandler.handleLoginStart(packet.data);
        if (response != null) {
          sendResponse(response);
        }
        break;
      default:
        print('[PacketProcessor] Unknown login packet: ${packet.id}');
    }
  }

  /// Processes play packets (active gameplay).
  ///
  /// Routes packets to PlayHandler for proper processing.
  static void _processPlayPacket(
    Packet packet,
    void Function(Packet) sendResponse, {
    Socket? socket,
  }) {
    if (socket == null) {
      // Can't process play packets without socket
      return;
    }

    // Get player session from socket (we need to track this)
    // For now, we'll use a simple approach: get session by socket
    final session = _getSessionBySocket(socket);
    if (session == null) {
      // No session found - ignore packet (client might be disconnecting)
      return;
    }

    // Route to PlayHandler
    PlayHandler.handlePacket(packet, socket, sendResponse, session);
  }

  /// Gets player session by socket.
  ///
  /// Note: This method is not ideal. In production, EnhancedConnectionHandler
  /// should maintain a socket-to-session mapping and pass session directly.
  /// For now, we return null and let EnhancedConnectionHandler handle it.
  static PlayerSession? _getSessionBySocket(Socket socket) {
    // EnhancedConnectionHandler should handle play packets directly
    // This method is a fallback but won't work properly
    return null;
  }
}
