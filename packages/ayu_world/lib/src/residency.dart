import 'budgets.dart';
import 'key.dart';
import 'record.dart';
import 'ticket.dart';

final class ChunkResidency {
  ChunkResidency(this.config);

  final ChunkConfig config;
  final Map<ChunkKey, ChunkRecord> records = {};
  final List<ChunkKey> lru = [];

  ChunkRecord obtain(ChunkKey key) =>
      records.putIfAbsent(key, () => ChunkRecord(key));

  ChunkRecord? operator [](ChunkKey key) => records[key];

  void drop(ChunkKey key) {
    records.remove(key);
    lru.remove(key);
  }

  int get accountedBytes {
    var n = 0;
    for (final record in records.values) {
      n += record.accountedBytes;
    }
    return n;
  }

  void noteUnreferenced(ChunkRecord record) {
    lru.remove(record.key);
    if (!record.referenced && record.phase == ChunkPhase.resident) {
      lru.add(record.key);
    }
  }

  void pin(ChunkRecord record) {
    lru.remove(record.key);
  }

  List<ChunkKey> evictionCandidates() => List<ChunkKey>.of(lru);
}
