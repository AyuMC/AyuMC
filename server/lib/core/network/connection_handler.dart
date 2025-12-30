import 'dart:async';
import 'dart:io';
import 'buffer/packet_buffer.dart';
import 'buffer/send_queue.dart';
import 'packet_processor.dart';
import '../protocol/packet.dart';

class ConnectionHandler {
  final Socket _socket;
  final PacketBuffer _receiveBuffer;
  final SendQueue _sendQueue;
  Timer? _processTimer;
  bool _isClosed = false;

  ConnectionHandler(this._socket)
    : _receiveBuffer = PacketBuffer(),
      _sendQueue = SendQueue(_socket) {
    _setupSocket();
  }

  void _setupSocket() {
    _socket.setOption(SocketOption.tcpNoDelay, true);

    _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );

    _startProcessing();
  }

  void _startProcessing() {
    _processTimer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => _processPackets(),
    );
  }

  void _onData(List<int> data) {
    if (_isClosed) return;
    _receiveBuffer.append(data);
  }

  void _processPackets() {
    if (_isClosed) return;

    int processed = 0;
    const maxPerCycle = 50;

    while (processed < maxPerCycle) {
      final packetData = _receiveBuffer.tryReadPacket();
      if (packetData == null) break;

      try {
        final packet = Packet.fromBytes(packetData);
        PacketProcessor.process(packet, _sendQueue.enqueue);
        processed++;
      } catch (e) {
        print('[Network] Packet processing error: $e');
        _close();
        return;
      }
    }
  }

  void _onError(Object error) {
    if (!_isClosed) {
      print('[Network] Socket error: $error');
      _close();
    }
  }

  void _onDone() {
    if (!_isClosed) {
      print(
        '[Network] Client disconnected: '
        '${_socket.remoteAddress.address}:${_socket.remotePort}',
      );
      _close();
    }
  }

  void _close() {
    if (_isClosed) return;
    _isClosed = true;

    _processTimer?.cancel();
    _receiveBuffer.clear();
    _sendQueue.clear();
    _socket.close();
  }

  void close() {
    _close();
  }
}
