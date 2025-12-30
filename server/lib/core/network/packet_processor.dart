import '../protocol/packet.dart';
import '../protocol/packet_reader.dart';
import 'status_handler.dart';

class PacketProcessor {
  PacketProcessor._();

  static void process(
    Packet packet,
    void Function(Packet) sendResponse,
  ) {
    final reader = PacketReader(packet.data);

    switch (packet.id) {
      case 0:
        _handleStatus(sendResponse);
        break;
      case 1:
        _handlePing(reader, sendResponse);
        break;
    }
  }

  static void _handleStatus(void Function(Packet) sendResponse) {
    final response = StatusHandler.handleStatusRequest();
    sendResponse(response);
  }

  static void _handlePing(
    PacketReader reader,
    void Function(Packet) sendResponse,
  ) {
    final response = StatusHandler.handlePingRequest(reader);
    sendResponse(response);
  }
}

