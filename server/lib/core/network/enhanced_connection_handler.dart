import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../connection/connection_state.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/packets/handshake/handshake_packet.dart';
import 'buffer/packet_buffer.dart';
import 'buffer/send_queue.dart';
import 'packet_processor.dart';

/// Enhanced connection handler with state management and optimizations.
///
/// Manages connection state transitions and routes packets accordingly.
class EnhancedConnectionHandler {
  final Socket _socket;
  final PacketBuffer _receiveBuffer;
  final SendQueue _sendQueue;
  Timer? _processTimer;
  bool _isClosed = false;

  ConnectionState _connectionState = ConnectionState.handshake;

  Function()? onClose;

  EnhancedConnectionHandler(this._socket)
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
    const kMaxPerCycle = 50;

    while (processed < kMaxPerCycle && !_isClosed) {
      final packetData = _receiveBuffer.tryReadPacket();
      if (packetData == null) break;

      if (!_processSinglePacket(packetData)) {
        return;
      }
      processed++;
    }
  }

  bool _processSinglePacket(Uint8List packetData) {
    try {
      final packet = Packet.fromBytes(packetData);

      // Handle handshake packet specially
      if (_connectionState == ConnectionState.handshake &&
          packet.id == PacketIds.handshakeHandshake) {
        _handleHandshake(packetData);
        return true;
      }

      // Process packet based on current state
      PacketProcessor.process(
        packet,
        _sendQueue.enqueue,
        state: _connectionState,
      );

      return true;
    } catch (e) {
      if (!_isClosed) {
        print('[EnhancedConnectionHandler] Packet processing error: $e');
        _close();
      }
      return false;
    }
  }

  void _handleHandshake(Uint8List packetData) {
    try {
      final handshake = HandshakePacket.parse(packetData);
      print('[EnhancedConnectionHandler] Handshake: $handshake');

      // Transition to the requested state
      _connectionState = handshake.nextState;
    } catch (e) {
      print('[EnhancedConnectionHandler] Handshake error: $e');
      _close();
    }
  }

  void _onError(Object error) {
    if (!_isClosed) {
      print('[EnhancedConnectionHandler] Socket error: $error');
      _close();
    }
  }

  void _onDone() {
    if (!_isClosed) {
      print(
        '[EnhancedConnectionHandler] Client disconnected: '
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

    onClose?.call();
  }

  void close() {
    _close();
  }
}
