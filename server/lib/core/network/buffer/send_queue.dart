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
  static const int _kBatchSize = 10;
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
      while (_queue.isNotEmpty && !_isClosed) {
        final batch = _extractBatch();
        _queue.removeRange(0, batch.length);

        if (!_sendBatch(batch)) {
          return;
        }

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

  List<Uint8List> _extractBatch() {
    return _queue.length > _kBatchSize
        ? _queue.sublist(0, _kBatchSize)
        : List<Uint8List>.from(_queue);
  }

  bool _sendBatch(List<Uint8List> batch) {
    try {
      // CRITICAL: Minecraft protocol requires each packet to be sent separately
      // DO NOT combine packets - each packet has its own length prefix
      // Combining packets causes the client to misread packet boundaries
      // Send each packet individually and flush to ensure immediate transmission
      for (final packetBytes in batch) {
        _socket.add(packetBytes);
        // Flush after each packet to ensure it's sent immediately
        // This prevents TCP from buffering and combining packets
        _socket.flush();
      }
      return true;
    } on SocketException {
      _closeQueue();
      return false;
    } catch (e) {
      if (ConnectionErrorHandler.isConnectionError(e)) {
        _closeQueue();
        return false;
      }
      rethrow;
    }
  }

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
