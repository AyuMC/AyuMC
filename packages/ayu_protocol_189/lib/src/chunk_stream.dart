import 'dart:typed_data';

import 'chunk_format.dart';
import 'visibility.dart';

/// Encoded protocol-47 columns. Implemented by the world pipeline adapter.
abstract interface class ChunkColumnSource {
  /// Registers interest in one column.
  ///
  /// [band] is the scheduling band (0 is the spawn-critical ring). [priorityRing]
  /// is the Chebyshev distance in chunks from the requesting player, used for
  /// near-first ordering. Older callers may omit it; the column is then served
  /// after columns that carry a distance.
  void acquire(
    Object holder,
    int chunkX,
    int chunkZ, {
    required int band,
    int? priorityRing,
  });

  void release(Object holder, int chunkX, int chunkZ);

  void releaseAll(Object holder);

  Uint8List? encoded(int chunkX, int chunkZ);

  void addReadyListener(void Function(int chunkX, int chunkZ) listener);

  void removeReadyListener(void Function(int chunkX, int chunkZ) listener);
}

int viewSquareRadius({required int serverChunks, int? clientViewChunks}) {
  final server = serverChunks.clamp(
    ViewDistanceVisibility.minChunks,
    ViewDistanceVisibility.maxServerChunks,
  );
  final client = (clientViewChunks ?? server).clamp(
    ViewDistanceVisibility.minChunks,
    ViewDistanceVisibility.maxChunks,
  );
  return client < server ? client : server;
}

/// Per-connection column streamer.
///
/// The queue holds only columns that are already encoded and resident. A
/// per-player cap on pending columns and pending bytes keeps a slow client
/// from accumulating the whole view in memory; cells that do not fit are left
/// in [desired] and picked up by a later slice.
///
/// Delivery order is nearest first using squared chunk distance with a
/// deterministic (x, z) tie-break. A column that leaves the required set
/// before it is sent is dropped instead of delivered, and a column that the
/// client already has is unloaded when the view moves away.
final class ChunkStreamSession {
  ChunkStreamSession({
    required this.holder,
    required this.source,
    required this.write,
    required this.isFlushPending,
    required this.beginFlush,
    this.onDelivery,
  });

  final Object holder;
  final ChunkColumnSource source;
  final void Function(Uint8List packet, {required bool unload}) write;
  final bool Function() isFlushPending;

  /// Must not call [Socket.flush]; that binds the IOSink and blocks entity
  /// writes.
  final void Function() beginFlush;

  /// Called with the microseconds a column waited between becoming resident
  /// and being handed to a socket. Optional; the endpoint samples histograms.
  final void Function(int micros)? onDelivery;

  /// Most resident-but-unsent columns kept ready at once. Set from live
  /// configuration before each slice.
  int maxPendingChunks = 512;

  /// Most bytes of ready column packets kept at once.
  int maxQueuedBytes = 8 * 1024 * 1024;

  int centerX = 0;
  int centerZ = 0;
  int radius = 0;
  bool standingHandedOff = false;

  /// Columns the client is expected to hold right now.
  final Set<(int, int)> desired = {};
  final Set<(int, int)> handedOff = {};
  final Set<(int, int)> _prefetch = {};
  final Map<(int, int), _Queued> _queued = {};

  /// Desired cells ordered near-first. Rebuilt when the view changes.
  final List<(int, int)> _order = [];
  int _cursor = 0;
  int _queuedDataCount = 0;
  int _queuedDataBytes = 0;

  /// Columns dropped because the view moved on before they could be sent.
  int unsentDrops = 0;

  /// Born-stale columns skipped when a slice finds them no longer desired.
  int staleSkipped = 0;

  int get queueDepth => _queuedDataCount;

  int get queuedBytes => _queuedDataBytes;

  int get unloadDepth => _queued.length - _queuedDataCount;

  int get desiredCount => desired.length;

  int get handedOffCount => handedOff.length;

  void updateView({
    required int chunkX,
    required int chunkZ,
    required int radius,
    bool prefetch = true,
  }) {
    centerX = chunkX;
    centerZ = chunkZ;
    this.radius = radius;
    final next = <(int, int)>{};
    for (var dz = -radius; dz <= radius; dz++) {
      for (var dx = -radius; dx <= radius; dx++) {
        next.add((chunkX + dx, chunkZ + dz));
      }
    }
    final prefetchRing = <(int, int)>{};
    if (prefetch) {
      final ring = radius + 1;
      for (var dz = -ring; dz <= ring; dz++) {
        for (var dx = -ring; dx <= ring; dx++) {
          final dist = dx.abs() > dz.abs() ? dx.abs() : dz.abs();
          if (dist == ring) prefetchRing.add((chunkX + dx, chunkZ + dz));
        }
      }
    }
    for (final cell in desired) {
      if (next.contains(cell)) continue;
      source.release(holder, cell.$1, cell.$2);
      _drop(cell);
      if (handedOff.remove(cell)) {
        // The client still holds it. Queue an unload so a later slice removes
        // it from the client's world unless it comes back first.
        _enqueueUnload(cell);
      }
    }
    for (final cell in _prefetch) {
      if (prefetchRing.contains(cell)) continue;
      source.release(holder, cell.$1, cell.$2);
    }
    desired
      ..clear()
      ..addAll(next);
    _prefetch
      ..clear()
      ..addAll(prefetchRing);
    for (final cell in next) {
      final dx = cell.$1 - chunkX;
      final dz = cell.$2 - chunkZ;
      final ring = dx.abs() > dz.abs() ? dx.abs() : dz.abs();
      source.acquire(holder, cell.$1, cell.$2, band: ring <= 1 ? 0 : 1, priorityRing: ring);
    }
    for (final cell in prefetchRing) {
      final dx = cell.$1 - chunkX;
      final dz = cell.$2 - chunkZ;
      final ring = dx.abs() > dz.abs() ? dx.abs() : dz.abs();
      source.acquire(holder, cell.$1, cell.$2, band: 2, priorityRing: ring);
    }
    _rebuildOrder();
    if (handedOff.contains((chunkX, chunkZ))) standingHandedOff = true;
  }

  void columnReady(int chunkX, int chunkZ) {
    final cell = (chunkX, chunkZ);
    if (!desired.contains(cell) || handedOff.contains(cell)) return;
    _enqueueIfRoom(cell);
  }

  void markHandedOff(int chunkX, int chunkZ) {
    final cell = (chunkX, chunkZ);
    handedOff.add(cell);
    _drop(cell);
    if (chunkX == centerX && chunkZ == centerZ) standingHandedOff = true;
  }

  bool get standingReady =>
      handedOff.contains((centerX, centerZ)) ||
      source.encoded(centerX, centerZ) != null;

  /// Writes ready columns until [maxBytes] worth of packets has been handed to
  /// the socket. At least one packet can be written per call; the remainder
  /// stays queued. Returns the bytes written.
  int sendSlice(int maxBytes) {
    if (isFlushPending() || maxBytes <= 0) return 0;
    _topUp();
    if (_queued.isEmpty) return 0;
    final order = _queued.values.toList()..sort(_nearFirst);
    var sent = 0;
    for (final item in order) {
      if (sent >= maxBytes) break;
      final cell = (item.x, item.z);
      if (item.unload) {
        if (desired.contains(cell) && !handedOff.contains(cell)) {
          _drop(cell);
          continue;
        }
        final packet = encodeChunkUnload(chunkX: item.x, chunkZ: item.z);
        write(packet, unload: true);
        sent += packet.length;
        handedOff.remove(cell);
        _drop(cell);
        continue;
      }
      if (!desired.contains(cell)) {
        if (!handedOff.contains(cell)) unsentDrops++;
        _drop(cell);
        continue;
      }
      if (handedOff.contains(cell)) {
        _drop(cell);
        continue;
      }
      final packet = source.encoded(item.x, item.z);
      if (packet == null) {
        // The column left residency before it was sent. The top-up scan will
        // find it again if it becomes resident while still desired.
        _drop(cell);
        continue;
      }
      write(packet, unload: false);
      sent += packet.length;
      final waited = item.readyAtMicros;
      if (waited != 0) onDelivery?.call(_nowMicros() - waited);
      markHandedOff(item.x, item.z);
    }
    if (sent > 0) beginFlush();
    return sent;
  }

  void close() {
    source.releaseAll(holder);
    desired.clear();
    handedOff.clear();
    _prefetch.clear();
    _order.clear();
    _queued.clear();
    _queuedDataCount = 0;
    _queuedDataBytes = 0;
    _cursor = 0;
  }

  final Stopwatch _clock = Stopwatch()..start();

  int _nowMicros() => _clock.elapsedMicroseconds;

  int _nearFirst(_Queued a, _Queued b) {
    final da = _distanceSquared(a.x, a.z);
    final db = _distanceSquared(b.x, b.z);
    if (da != db) return da.compareTo(db);
    if (a.x != b.x) return a.x.compareTo(b.x);
    return a.z.compareTo(b.z);
  }

  int _distanceSquared(int x, int z) {
    final dx = x - centerX;
    final dz = z - centerZ;
    return dx * dx + dz * dz;
  }

  /// Rebuilds the near-first candidate list for one view. Called when the
  /// player crosses a chunk border or the radius changes, not per slice.
  void _rebuildOrder() {
    _order
      ..clear()
      ..addAll(desired)
      ..sort((a, b) {
        final da = _distanceSquared(a.$1, a.$2);
        final db = _distanceSquared(b.$1, b.$2);
        if (da != db) return da.compareTo(db);
        if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
        return a.$2.compareTo(b.$2);
      });
    _cursor = 0;
  }

  /// Pulls resident columns from [desired] into the ready queue without
  /// exceeding the pending caps. The scan is bounded per call.
  void _topUp() {
    if (_order.isEmpty) return;
    if (_queuedDataCount >= maxPendingChunks ||
        _queuedDataBytes >= maxQueuedBytes) {
      return;
    }
    var scanned = 0;
    var wraps = 0;
    while (_queuedDataCount < maxPendingChunks &&
        _queuedDataBytes < maxQueuedBytes) {
      if (_cursor >= _order.length) {
        _cursor = 0;
        wraps++;
        if (wraps > 1) return;
      }
      final cell = _order[_cursor++];
      scanned++;
      if (scanned > 512) return;
      if (handedOff.contains(cell) || _queued.containsKey(cell)) continue;
      final packet = source.encoded(cell.$1, cell.$2);
      if (packet == null) continue;
      _enqueueData(cell, packet.length);
    }
  }

  void _enqueueIfRoom((int, int) cell) {
    if (_queued.containsKey(cell)) return;
    if (_queuedDataCount >= maxPendingChunks ||
        _queuedDataBytes >= maxQueuedBytes) {
      return;
    }
    final packet = source.encoded(cell.$1, cell.$2);
    if (packet == null) return;
    _enqueueData(cell, packet.length);
  }

  void _enqueueData((int, int) cell, int bytes) {
    _queued[cell] = _Queued(
      cell.$1,
      cell.$2,
      unload: false,
      bytes: bytes,
      readyAtMicros: _nowMicros(),
    );
    _queuedDataCount++;
    _queuedDataBytes += bytes;
  }

  void _enqueueUnload((int, int) cell) {
    final existing = _queued[cell];
    if (existing != null && existing.unload) return;
    if (existing != null) {
      _queued.remove(cell);
      _queuedDataCount--;
      _queuedDataBytes -= existing.bytes;
    }
    _queued[cell] = _Queued(cell.$1, cell.$2, unload: true);
  }

  void _drop((int, int) cell) {
    final existing = _queued.remove(cell);
    if (existing == null) return;
    if (!existing.unload) {
      _queuedDataCount--;
      _queuedDataBytes -= existing.bytes;
    }
  }
}

final class _Queued {
  _Queued(
    this.x,
    this.z, {
    required this.unload,
    this.bytes = 0,
    this.readyAtMicros = 0,
  });

  final int x;
  final int z;
  final bool unload;
  final int bytes;
  final int readyAtMicros;
}
