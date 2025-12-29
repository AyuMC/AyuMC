import 'dart:io';
import 'dart:typed_data';
import '../protocol/packet.dart';
import '../protocol/packet_reader.dart';
import 'status_handler.dart';
import '../constants/network_constants.dart';

class ConnectionHandler {
  final Socket _socket;
  final List<int> _buffer = [];

  ConnectionHandler(this._socket) {
    _setupSocket();
  }

  void _setupSocket() {
    _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );

    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    _processPackets();
  }

  void _processPackets() {
    while (_buffer.isNotEmpty) {
      try {
        final packetLength = _readVarIntFromBuffer();
        if (packetLength == null) {
          break;
        }

        if (packetLength > NetworkConstants.maxPacketSize) {
          _socket.close();
          return;
        }

        if (_buffer.length < packetLength) {
          break;
        }

        final packetData = Uint8List.fromList(_buffer.sublist(0, packetLength));
        _buffer.removeRange(0, packetLength);

        _handlePacket(packetData);
      } catch (e) {
        print('[Network] Error processing packet: $e');
        _socket.close();
        return;
      }
    }
  }

  int? _readVarIntFromBuffer() {
    if (_buffer.isEmpty) return null;

    int value = 0;
    int position = 0;
    int offset = 0;

    while (true) {
      if (offset >= _buffer.length) return null;

      final currentByte = _buffer[offset];
      value |= (currentByte & 0x7F) << (position * 7);

      if ((currentByte & 0x80) == 0) {
        return value;
      }

      offset++;
      position++;

      if (position >= 5) {
        return null;
      }
    }
  }

  void _handlePacket(Uint8List data) {
    try {
      final packet = Packet.fromBytes(data);
      final reader = PacketReader(packet.data);

      if (packet.id == 0) {
        _handleStatusRequest();
      } else if (packet.id == 1) {
        _handlePingRequest(reader);
      }
    } catch (e) {
      print('[Network] Error handling packet: $e');
    }
  }

  void _handleStatusRequest() {
    final response = StatusHandler.handleStatusRequest();
    _sendPacket(response);
  }

  void _handlePingRequest(PacketReader reader) {
    final response = StatusHandler.handlePingRequest(reader);
    _sendPacket(response);
  }

  void _sendPacket(Packet packet) {
    try {
      final bytes = packet.toBytes();
      _socket.add(bytes);
    } catch (e) {
      print('[Network] Error sending packet: $e');
    }
  }

  void _onError(Object error) {
    print('[Network] Socket error: $error');
  }

  void _onDone() {
    print(
      '[Network] Client disconnected: '
      '${_socket.remoteAddress.address}:${_socket.remotePort}',
    );
  }

  void close() {
    _socket.close();
  }
}
