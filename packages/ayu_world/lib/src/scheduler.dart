import 'budgets.dart';
import 'key.dart';
import 'record.dart';
import 'ticket.dart';

/// Near-first chunk scheduler.
///
/// Work is bucketed by request band ([TicketReason]) and, inside a band, by
/// the Chebyshev distance in chunks from the player that asked for the column.
/// [pick] walks the nearest rings first, so the chunks a player is standing in
/// are started before the far edge of the view square. Because the buckets are
/// keyed by distance instead of by chunk coordinate, a lexicographic X/Z order
/// can no longer put a far corner ahead of the column under the player.
///
/// Removal is O(1): a key remembers its band and ring. That matters while a
/// player crosses chunk borders and obsolete requests are cancelled.
///
/// The classes that used to read `bands` directly are gone; only
/// [queuedCount], [enqueue], [remove], [promoteAged] and [pick] are public.
final class ChunkScheduler {
  ChunkScheduler(this.config);

  /// Distances above this ring share the farthest bucket. The server view cap
  /// is far below it, so only out-of-range speculative work lands there.
  static const maxRing = 64;

  final ChunkConfig config;

  final List<List<Set<ChunkKey>>> _bands = [
    for (var i = 0; i < TicketReason.values.length; i++)
      List.generate(maxRing + 2, (_) => <ChunkKey>{}),
  ];
  final Map<ChunkKey, _Slot> _slots = {};

  /// Dequeue attempts. Exposed for tests and diagnostics.
  int dequeues = 0;

  /// Oldest waited columns promoted to a better band.
  int agedPromotions = 0;

  int _rotation = 0;

  int get queuedCount => _slots.length;

  void enqueue(ChunkRecord record) {
    remove(record.key);
    final reason = record.effectiveReason;
    final ring = _ringFor(record);
    _bands[reason.index][ring].add(record.key);
    _slots[record.key] = _Slot(reason.index, ring);
    record.phase = ChunkPhase.queued;
  }

  void remove(ChunkKey key) {
    final slot = _slots.remove(key);
    if (slot == null) return;
    _bands[slot.band][slot.ring].remove(key);
  }

  bool contains(ChunkKey key) => _slots.containsKey(key);

  /// Promotes every queued column that waited at least [afterMicros] into the
  /// next better band (background work only). Called from the pipeline tick on
  /// a slow cadence, not from [pick]; the old implementation rebuilt an aged
  /// map over every resident record on each dequeue.
  int promoteAged(
    Map<ChunkKey, ChunkRecord> records,
    int nowMicros, {
    int afterMicros = 2000000,
  }) {
    var promoted = 0;
    for (final entry in _slots.entries.toList()) {
      final record = records[entry.key];
      if (record == null ||
          record.phase != ChunkPhase.queued ||
          record.agedTo != null) {
        continue;
      }
      if (nowMicros - record.queuedAtMicros < afterMicros) continue;
      final better = record.highestReason.aged;
      if (better.index >= record.highestReason.index) {
        record.agedTo = record.highestReason;
      } else {
        record.agedTo = better;
      }
      remove(record.key);
      enqueue(record);
      promoted++;
    }
    if (promoted > 0) agedPromotions += promoted;
    return promoted;
  }

  ChunkKey? pick({
    required Map<ChunkKey, ChunkRecord> records,
    required Pressure pressure,
    required bool Function(ChunkRecord record) canStart,
    required int nowMicros,
  }) {
    dequeues++;
    final backgroundFirst = pressure != Pressure.critical && dequeues % 8 == 0;
    if (backgroundFirst) {
      final background = _firstFitting(
        TicketReason.p4.index,
        records,
        canStart,
      );
      if (background != null) return background;
    }
    final maxBand = pressure == Pressure.critical
        ? TicketReason.p0.index
        : TicketReason.p4.index;
    for (var band = 0; band <= maxBand; band++) {
      final key = _firstFitting(band, records, canStart);
      if (key != null) return key;
    }
    return null;
  }

  ChunkKey? _firstFitting(
    int band,
    Map<ChunkKey, ChunkRecord> records,
    bool Function(ChunkRecord record) canStart,
  ) {
    final rings = _bands[band];
    for (var ring = 0; ring < rings.length; ring++) {
      final bucket = rings[ring];
      if (bucket.isEmpty) continue;
      final key = _scan(bucket, records, canStart);
      if (key != null) return key;
    }
    return null;
  }

  /// Walks a bucket starting at a rotating offset so equal-priority requests
  /// from different players take turns. The scan is capped so one huge bucket
  /// cannot monopolize a tick; a later [pick] resumes near the same place.
  ChunkKey? _scan(
    Set<ChunkKey> bucket,
    Map<ChunkKey, ChunkRecord> records,
    bool Function(ChunkRecord record) canStart,
  ) {
    const budget = 128;
    final start = bucket.isEmpty ? 0 : _rotation++ % bucket.length;
    var seen = 0;
    var skipped = 0;
    for (final key in bucket) {
      if (skipped++ < start) continue;
      if (seen++ >= budget) return null;
      final record = records[key];
      if (record == null || record.phase != ChunkPhase.queued) continue;
      if (!canStart(record)) continue;
      return key;
    }
    return null;
  }

  int _ringFor(ChunkRecord record) {
    final distance = record.demandRing;
    if (distance == null) return maxRing + 1;
    if (distance < 0) return 0;
    if (distance > maxRing) return maxRing;
    return distance;
  }
}

final class _Slot {
  const _Slot(this.band, this.ring);
  final int band;
  final int ring;
}
