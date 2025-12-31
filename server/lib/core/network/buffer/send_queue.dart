import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../protocol/packet.dart';
import '../utils/connection_error_handler.dart';
import '../optimization/memory_pool.dart';

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
      final combined = _combineBytes(batch);
      _socket.add(combined);
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

  Uint8List _combineBytes(List<Uint8List> batches) {
    int totalLength = 0;
    for (final batch in batches) {
      totalLength += batch.length;
    }

    // Use memory pool for buffer allocation (zero-copy optimization)
    final memoryPool = BufferMemoryPool();
    final combined = memoryPool.acquire(totalLength);

    int offset = 0;
    for (final batch in batches) {
      combined.setRange(offset, offset + batch.length, batch);
      offset += batch.length;
    }

    // Return a copy since we'll release the pooled buffer
    // In production, we could use TransferableTypedData for true zero-copy
    final result = Uint8List.fromList(combined.sublist(0, totalLength));
    memoryPool.release(combined);

    return result;
  }

  void clear() {
    _closeQueue();
  }
}
