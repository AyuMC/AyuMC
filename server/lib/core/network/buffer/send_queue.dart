import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../protocol/packet.dart';

class SendQueue {
  final Socket _socket;
  final List<Uint8List> _queue = [];
  bool _isSending = false;
  static const int _batchSize = 10;
  static const int _maxQueueSize = 1000;

  SendQueue(this._socket);

  void enqueue(Packet packet) {
    if (_queue.length >= _maxQueueSize) {
      return;
    }

    final bytes = packet.toBytes();
    _queue.add(bytes);

    if (!_isSending) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    if (_queue.isEmpty || _isSending) return;

    _isSending = true;

    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.length > _batchSize
            ? _queue.sublist(0, _batchSize)
            : List<Uint8List>.from(_queue);

        _queue.removeRange(0, batch.length);

        final combined = _combineBytes(batch);
        _socket.add(combined);

        if (_queue.isNotEmpty) {
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      print('[Network] Send queue error: $e');
    } finally {
      _isSending = false;
    }
  }

  Uint8List _combineBytes(List<Uint8List> batches) {
    int totalLength = 0;
    for (final batch in batches) {
      totalLength += batch.length;
    }

    final combined = Uint8List(totalLength);
    int offset = 0;
    for (final batch in batches) {
      combined.setRange(offset, offset + batch.length, batch);
      offset += batch.length;
    }

    return combined;
  }

  void clear() {
    _queue.clear();
  }
}

