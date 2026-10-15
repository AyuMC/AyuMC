/// Bounded, low-overhead counters and histograms for the chunk pipeline.
///
/// Samples are capped at 1024 entries per histogram (trimmed to 512), so a
/// long-running server cannot grow this object without bound. Nothing here
/// writes a log line per chunk.
final class ChunkStats {
  int generates = 0;
  int reads = 0;
  int storageHits = 0;
  int storageMisses = 0;
  int dedupHits = 0;
  int evictions = 0;
  int dirtyWrites = 0;
  int failedLoads = 0;
  int encodes = 0;
  int workerJobs = 0;
  int workerBytes = 0;
  int staleResults = 0;
  int cancelled = 0;
  int retries = 0;
  int blockedEvictions = 0;
  int storageFailures = 0;
  int storageReadMicros = 0;
  int storageWriteMicros = 0;
  int inFlight = 0;
  int generateMicros = 0;
  int finalizeMicros = 0;
  int queuedKeys = 0;
  int residentKeys = 0;
  int wantedKeys = 0;
  int accountedBytes = 0;
  int ticketsP0 = 0;
  int ticketsP1 = 0;
  int ticketsP2 = 0;
  int ticketsP3 = 0;
  int ticketsP4 = 0;
  int dirtyKeys = 0;
  int probeLatenessMicros = 0;
  String pressure = 'normal';
  int rss = 0;

  /// Records currently reading storage or generating.
  int generating = 0;

  /// Payload bytes held by records that are queued but not yet started.
  int queuedBytes = 0;

  /// Worker pool shape: configured isolate count and how many are busy.
  int workerActive = 0;
  int workerBusy = 0;

  /// Columns cancelled before they were sent because the view moved on.
  int unsentDrops = 0;

  /// Server view cap currently in force, in chunks.
  int viewChunks = 0;

  /// Protocol-47 transport compression, counted at the socket boundary.
  int compressionFrames = 0;
  int compressionRawBytes = 0;
  int compressionWireBytes = 0;

  final List<int> ticketToResident = [];
  final List<int> wantedWait = [];
  final List<int> queuedWait = [];
  final List<int> lookupMicros = [];
  final List<int> deliveryWaitMicros = [];

  void sample(List<int> into, int micros) {
    into.add(micros);
    if (into.length > 1024) {
      into.removeRange(0, into.length - 512);
    }
  }

  Map<String, int> percentiles(List<int> samples) {
    if (samples.isEmpty) {
      return const {'p50': 0, 'p95': 0, 'p99': 0};
    }
    final sorted = [...samples]..sort();
    int at(double q) => sorted[((sorted.length - 1) * q).round()];
    return {'p50': at(0.50), 'p95': at(0.95), 'p99': at(0.99)};
  }

  double get storageHitRate {
    final total = storageHits + storageMisses;
    if (total == 0) return 0;
    return storageHits / total;
  }

  Map<String, Object?> snapshot() => {
    'chunkGenerates': generates,
    'chunkReads': reads,
    'chunkStorageHits': storageHits,
    'chunkStorageMisses': storageMisses,
    'chunkStorageHitRate': storageHitRate,
    'chunkDedup': dedupHits,
    'chunkEvictions': evictions,
    'chunkDirtyWrites': dirtyWrites,
    'chunkFailedLoads': failedLoads,
    'chunkEncodes': encodes,
    'chunkWorkerJobs': workerJobs,
    'chunkWorkerBytes': workerBytes,
    'chunkWorkerActive': workerActive,
    'chunkWorkerBusy': workerBusy,
    'chunkStaleResults': staleResults,
    'chunkCancelled': cancelled,
    'chunkUnsentDrops': unsentDrops,
    'chunkRetries': retries,
    'chunkBlockedEvictions': blockedEvictions,
    'chunkStorageFailures': storageFailures,
    'chunkStorageReadMicros': storageReadMicros,
    'chunkStorageWriteMicros': storageWriteMicros,
    'chunkInFlight': inFlight,
    'chunkGenerating': generating,
    'chunkGenerateMicros': generateMicros,
    'chunkFinalizeMicros': finalizeMicros,
    'chunkQueue': queuedKeys,
    'chunkQueuedBytes': queuedBytes,
    'chunkResident': residentKeys,
    'chunkWanted': wantedKeys,
    'chunkAccountedBytes': accountedBytes,
    'chunkTicketsP0': ticketsP0,
    'chunkTicketsP1': ticketsP1,
    'chunkTicketsP2': ticketsP2,
    'chunkTicketsP3': ticketsP3,
    'chunkTicketsP4': ticketsP4,
    'chunkDirty': dirtyKeys,
    'chunkProbeLateMicros': probeLatenessMicros,
    'chunkPressure': pressure,
    'chunkViewChunks': viewChunks,
    'chunkCompressionFrames': compressionFrames,
    'chunkCompressionRawBytes': compressionRawBytes,
    'chunkCompressionWireBytes': compressionWireBytes,
    'rss': rss,
    'chunkResidentLatency': percentiles(ticketToResident),
    'chunkWantedWait': percentiles(wantedWait),
    'chunkQueuedWait': percentiles(queuedWait),
    'chunkLookupLatency': percentiles(lookupMicros),
    'chunkDeliveryWait': percentiles(deliveryWaitMicros),
  };
}
