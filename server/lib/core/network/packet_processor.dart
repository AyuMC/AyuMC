import '../connection/connection_state.dart';
import '../handlers/login_handler.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/packet_reader.dart';
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
  static void process(
    Packet packet,
    void Function(Packet) sendResponse, {
    ConnectionState state = ConnectionState.status,
  }) {
    switch (state) {
      case ConnectionState.status:
        _processStatusPacket(packet, sendResponse);
        break;
      case ConnectionState.login:
        _processLoginPacket(packet, sendResponse);
        break;
      case ConnectionState.play:
        _processPlayPacket(packet, sendResponse);
        break;
      default:
        print('[PacketProcessor] Unhandled state: $state');
    }
  }

  /// Processes status packets (server list ping).
  static void _processStatusPacket(
    Packet packet,
    void Function(Packet) sendResponse,
  ) {
    switch (packet.id) {
      case PacketIds.statusRequest:
        final response = StatusHandler.handleStatusRequest();
        sendResponse(response);
        break;
      case PacketIds.statusPing:
        final reader = PacketReader(packet.data);
        final response = StatusHandler.handlePingRequest(reader);
        sendResponse(response);
        break;
      default:
        print('[PacketProcessor] Unknown status packet: ${packet.id}');
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
  static void _processPlayPacket(
    Packet packet,
    void Function(Packet) sendResponse,
  ) {
    // TODO: Implement play packet handling
    print('[PacketProcessor] Play packet received: ${packet.id}');
  }
}
