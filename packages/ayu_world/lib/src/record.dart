import 'dart:typed_data';

import 'key.dart';
import 'payload.dart';
import 'ticket.dart';

final class ChunkRecord {
  ChunkRecord(this.key);

  final ChunkKey key;
  ChunkPhase phase = ChunkPhase.wanted;
  int jobEpoch = 0;
  int snapshotGeneration = 0;
  ChunkPayload? payload;
  Uint8List? encoded;
  bool dirty = false;
  bool playerModified = false;
  bool regenerable = true;
  String? generatorId;
  int? generatorVersion;
  DateTime? failedUntil;
  int ioAttempts = 0;
  int generateAttempts = 0;
  int ticketedAtMicros = 0;
  int queuedAtMicros = 0;
  int startedAtMicros = 0;

  /// Chebyshev distance in chunks from the holder that most recently asked for
  /// this column. Drives near-first scheduling. `null` when nobody supplied a
  /// distance, which keeps the legacy FIFO order inside a band.
  int? demandRing;

  /// Set once when a queued column waited long enough to be promoted a band.
  /// The scheduler serves [effectiveReason] instead of [highestReason].
  TicketReason? agedTo;
  Object? fairnessHolder;
  final Map<Object, TicketReason> tickets = {};

  bool get referenced => tickets.isNotEmpty;

  TicketReason get highestReason {
    var best = TicketReason.p4;
    for (final reason in tickets.values) {
      if (reason.index < best.index) best = reason;
    }
    return best;
  }

  /// The band the scheduler actually serves. Aging promotes waiting background
  /// work so speculative requests cannot sit behind a continuous stream of
  /// player-required chunks forever.
  TicketReason get effectiveReason => agedTo ?? highestReason;

  int get accountedBytes {
    var n = 0;
    final snap = payload;
    if (snap != null) n += snap.byteLength;
    final packet = encoded;
    if (packet != null) n += packet.length;
    return n;
  }

  void addTicket(Object holder, TicketReason reason) {
    final previous = tickets[holder];
    if (previous == null || reason.index < previous.index) {
      tickets[holder] = reason;
    }
  }

  bool removeTicket(Object holder) => tickets.remove(holder) != null;
}
