import 'dart:async';

import 'package:ayu_package/ayu_package.dart';

/// Sends one frame; returns `false` when the channel refused it (congested
/// or closed).
typedef FrameSender = bool Function(String method, Object params);

/// Bounded, batching outbound queue towards one worker.
///
/// Items are grouped per type (contract or primitive id); each type carries
/// the [DeliverySpec] that governs its queue: limit, overflow policy
/// (gap or coalesce) and whether several items may share one frame.
/// Flushing happens once per event-loop turn; when the channel pushes back
/// the items stay queued and the flush is retried shortly, so a slow worker
/// loses events only through its declared overflow policy, never by
/// blocking the host.
final class WorkerOutbox {
  WorkerOutbox({
    required FrameSender send,
    required this.singleMethod,
    required this.batchMethod,
    required this.maxBatchItems,
    required this.onGap,
    this.retryDelay = const Duration(milliseconds: 5),
  }) : _send = send;

  final FrameSender _send;
  final String singleMethod;
  final String batchMethod;
  final int maxBatchItems;

  /// Reports dropped items per type after they were dropped.
  final void Function(String type, int dropped) onGap;
  final Duration retryDelay;

  final Map<String, _TypeQueue> _queues = {};
  bool _flushScheduled = false;
  Timer? _retry;
  bool _closed = false;

  int get queuedItems => _queues.values.fold(0, (sum, q) => sum + q.items.length);

  /// Queues [payload] (an already encoded envelope) for [type].
  void enqueue(String type, DeliverySpec spec, Map<String, Object?> payload) {
    if (_closed) return;
    final queue = _queues.putIfAbsent(type, () => _TypeQueue(spec));
    if (spec.overflow == OverflowPolicy.coalesce && spec.coalesceKey != null) {
      final key = (payload['data'] as Map?)?[spec.coalesceKey];
      if (key != null) {
        final index = queue.items.indexWhere((item) => (item['data'] as Map?)?[spec.coalesceKey] == key);
        if (index >= 0) {
          queue.items[index] = payload;
          queue.coalesced++;
          _scheduleFlush();
          return;
        }
      }
    }
    queue.items.add(payload);
    if (queue.items.length > spec.queueLimit) {
      queue.items.removeAt(0);
      queue.dropped++;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _closed) return;
    _flushScheduled = true;
    scheduleMicrotask(flush);
  }

  /// Emits gaps first, then frames, until the queues are empty or the
  /// channel pushes back.
  void flush() {
    _flushScheduled = false;
    _retry?.cancel();
    _retry = null;
    if (_closed) return;
    for (final entry in _queues.entries) {
      final queue = entry.value;
      if (queue.dropped > 0) {
        final dropped = queue.dropped;
        queue.dropped = 0;
        onGap(entry.key, dropped);
      }
      while (queue.items.isNotEmpty) {
        final bool sent;
        if (queue.spec.batching && queue.items.length > 1) {
          final count = queue.items.length < maxBatchItems ? queue.items.length : maxBatchItems;
          sent = _send(batchMethod, {'items': queue.items.sublist(0, count)});
          if (sent) queue.items.removeRange(0, count);
        } else {
          sent = _send(singleMethod, queue.items.first);
          if (sent) queue.items.removeAt(0);
        }
        if (!sent) {
          _retry = Timer(retryDelay, flush);
          return;
        }
      }
    }
    _queues.removeWhere((_, q) => q.items.isEmpty && q.dropped == 0);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _queues.clear();
  }
}

final class _TypeQueue {
  _TypeQueue(this.spec);

  final DeliverySpec spec;
  final List<Map<String, Object?>> items = [];
  int dropped = 0;
  int coalesced = 0;
}
