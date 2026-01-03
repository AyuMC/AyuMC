import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../protocol/packet.dart';
import '../utils/connection_error_handler.dart';

class SendQueue {
  final Socket _socket;
  final List<Uint8List> _queue = [];
  bool _isSending = false;
  bool _isClosed = false;
  static const int _kMaxQueueSize = 1000;
  SendQueue(this._socket);

  void enqueue(Packet packet) {
    if (_isClosed || _queue.length >= _kMaxQueueSize) {
      return;
    }

    try {
      final bytes = packet.toBytes();

      // Validate packet bytes are not empty
      if (bytes.isEmpty) {
        throw Exception('Packet bytes are empty');
      }

      // Debug: Log packet info for Join Game packets
      if (packet.id == 0x28) {
        print(
          '[SendQueue] Join Game packet: ID=${packet.id}, dataLength=${packet.data.length}, totalBytes=${bytes.length}',
        );
        // Verify packet can be read back
        try {
          final testPacket = Packet.fromBytes(bytes);
          if (testPacket.id != packet.id) {
            throw Exception(
              'Packet ID mismatch after encoding: expected ${packet.id}, got ${testPacket.id}',
            );
          }
          if (testPacket.data.length != packet.data.length) {
            throw Exception(
              'Packet data length mismatch: expected ${packet.data.length}, got ${testPacket.data.length}',
            );
          }
        } catch (e) {
          print('[SendQueue] ERROR: Packet encoding verification failed: $e');
          rethrow;
        }
      }

      _queue.add(bytes);

      if (!_isSending) {
        _processQueue();
      }
    } catch (e) {
      // Log error but don't crash - this helps identify encoding issues
      print('[SendQueue] Error encoding packet: $e');
      rethrow;
    }
  }

  Future<void> _processQueue() async {
    if (_isClosed || _queue.isEmpty || _isSending) return;

    _isSending = true;

    try {
      // CRITICAL: Send packets one by one, not in batches
      // This ensures each packet is sent immediately and separately
      while (_queue.isNotEmpty && !_isClosed) {
        final packetBytes = _queue.removeAt(0);

        try {
          // Validate packet bytes before sending
          if (packetBytes.isEmpty) {
            throw Exception('Cannot send empty packet');
          }

          // Send packet immediately
          _socket.add(packetBytes);
          // Note: Socket in Dart doesn't have flush(), but add() should send immediately
          // We send one packet at a time to ensure proper packet boundaries
        } on SocketException {
          // Connection closed or write failed - this is normal when client disconnects
          _closeQueue();
          return;
        } catch (e) {
          if (ConnectionErrorHandler.isConnectionError(e)) {
            _closeQueue();
            return;
          }
          // Log unexpected errors for debugging
          print('[SendQueue] Unexpected error sending packet: $e');
          rethrow;
        }

        // Yield to event loop after each packet to prevent blocking
        if (_queue.isNotEmpty) {
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      _handleError(e);
    } finally {
      _isSending = false;
    }
  }

  // REMOVED: _extractBatch and _sendBatch are no longer used
  // Packets are now sent one by one in _processQueue to ensure proper boundaries

  void _handleError(Object error) {
    if (!_isClosed) {
      _closeQueue();
    }
  }

  void _closeQueue() {
    _isClosed = true;
    _queue.clear();
  }

  // REMOVED: _combineBytes is no longer used
  // Minecraft protocol requires packets to be sent separately, not combined
  // Each packet must be sent individually to maintain proper packet boundaries

  void clear() {
    _closeQueue();
  }
}
