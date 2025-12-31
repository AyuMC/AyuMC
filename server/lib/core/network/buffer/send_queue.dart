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

    final bytes = packet.toBytes();
    _queue.add(bytes);

    if (!_isSending) {
      _processQueue();
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
          // Send packet immediately
          _socket.add(packetBytes);
          // Note: Socket in Dart doesn't have flush(), but add() should send immediately
          // We send one packet at a time to ensure proper packet boundaries
        } on SocketException {
          _closeQueue();
          return;
        } catch (e) {
          if (ConnectionErrorHandler.isConnectionError(e)) {
            _closeQueue();
            return;
          }
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
