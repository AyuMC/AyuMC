import 'dart:async';
import 'dart:typed_data';

/// A high-performance packet batcher for network I/O optimization.
///
/// The [NetworkPacketBatcher] combines small packets into larger batches
/// to reduce the number of system calls and improve network efficiency.
/// Batches are automatically flushed based on size or time constraints.
///
/// Example:
/// ```dart
/// final batcher = NetworkPacketBatcher((packets) {
///   socket.add(combinePackets(packets));
/// });
///
/// batcher.add(packet);
/// Automatically flushes when batch is full or timer expires
/// ```
class NetworkPacketBatcher {
  final List<Uint8List> _batch = [];
  Timer? _flushTimer;
  final Function(List<Uint8List>) _onFlush;

  static const int kMaxBatchSize = 20;
  static const int kFlushIntervalMs = 5;
  static const int kMaxBatchBytes = 32768;

  int _currentBatchBytes = 0;

  NetworkPacketBatcher(this._onFlush);

  /// Adds a packet to the current batch.
  ///
  /// The batch will be automatically flushed if it reaches [kMaxBatchSize]
  /// packets or [kMaxBatchBytes] bytes.
  void add(Uint8List packet) {
    _batch.add(packet);
    _currentBatchBytes += packet.length;

    if (_shouldFlushImmediately()) {
      flush();
    } else {
      _scheduleDelayedFlush();
    }
  }

  bool _shouldFlushImmediately() {
    return _batch.length >= kMaxBatchSize ||
        _currentBatchBytes >= kMaxBatchBytes;
  }

  void _scheduleDelayedFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: kFlushIntervalMs), flush);
  }

  /// Immediately flushes the current batch.
  void flush() {
    if (_batch.isEmpty) return;

    _flushTimer?.cancel();
    _onFlush(List.from(_batch));

    _batch.clear();
    _currentBatchBytes = 0;
  }

  /// Disposes the batcher, canceling pending flushes and clearing the batch.
  void dispose() {
    _flushTimer?.cancel();
    _batch.clear();
    _currentBatchBytes = 0;
  }

  /// Returns the current number of packets in the batch.
  int get batchSize => _batch.length;

  /// Returns the current total bytes in the batch.
  int get batchBytes => _currentBatchBytes;
}
