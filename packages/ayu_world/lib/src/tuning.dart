import 'budgets.dart';

/// Live-adjustable pipeline limits.
///
/// The pipeline reads these fields instead of [ChunkConfig] for every value
/// that the configuration center may change while the server is running.
/// [ChunkConfig] still supplies the initial values and the fields that require
/// a restart or a world operation (generator identity, storage, worker mode).
///
/// Every write goes through [setFrom] so a rejected value leaves the previous
/// effective number in place. The engine owns the authoritative copy; the
/// manager never mutates this object directly.
final class ChunkTuning {
  ChunkTuning(ChunkConfig config)
    : _cacheMiB = config.cacheMiB,
      _queuedSoft = config.queuedSoft,
      _queuedHard = config.queuedHard,
      _perPlayerInFlight = config.perPlayerInFlight,
      _p0Bonus = config.p0Bonus,
      _diskReads = config.diskReads,
      _diskFlushes = config.diskFlushes,
      _pregenTickets = config.pregenTickets,
      _pregenInFlightBusy = config.pregenInFlightBusy,
      _pregenInFlightIdle = config.pregenInFlightIdle,
      _inlineBudgetMicros = config.inlineBudget.inMicroseconds,
      _globalQueuedChunkBytes = config.globalQueuedChunkBytes,
      _writeQueueBytes = config.writeQueueBytes,
      _groupCommitChunks = config.groupCommitChunks,
      _groupCommitMillis = config.groupCommit.inMilliseconds,
      _globalGenerationInFlight = config.globalGenerationInFlight;

  int _cacheMiB;
  int _queuedSoft;
  int _queuedHard;
  int _perPlayerInFlight;
  int _p0Bonus;
  int _diskReads;
  int _diskFlushes;
  int _pregenTickets;
  int _pregenInFlightBusy;
  int _pregenInFlightIdle;
  int _inlineBudgetMicros;
  int _globalQueuedChunkBytes;
  int _writeQueueBytes;
  int _groupCommitChunks;
  int _groupCommitMillis;
  int _globalGenerationInFlight;

  int get cacheMiB => _cacheMiB;
  int get queuedSoft => _queuedSoft;
  int get queuedHard => _queuedHard;
  int get perPlayerInFlight => _perPlayerInFlight;
  int get p0Bonus => _p0Bonus;
  int get diskReads => _diskReads;
  int get diskFlushes => _diskFlushes;
  int get pregenTickets => _pregenTickets;
  int get pregenInFlightBusy => _pregenInFlightBusy;
  int get pregenInFlightIdle => _pregenInFlightIdle;
  int get inlineBudgetMicros => _inlineBudgetMicros;
  int get globalQueuedChunkBytes => _globalQueuedChunkBytes;
  int get writeQueueBytes => _writeQueueBytes;
  int get groupCommitChunks => _groupCommitChunks;
  int get groupCommitMillis => _groupCommitMillis;
  int get globalGenerationInFlight => _globalGenerationInFlight;

  int get cacheBytes => _cacheMiB * 1024 * 1024;
  int get lowWaterBytes => cacheBytes * 4 ~/ 5;
  int get prefetchWaterBytes => cacheBytes * 9 ~/ 10;
  Duration get inlineBudget => Duration(microseconds: _inlineBudgetMicros);
  Duration get groupCommit => Duration(milliseconds: _groupCommitMillis);

  /// Applies one known key. Returns null when the key is unknown, otherwise
  /// the previous value so a caller can roll back.
  int? setFrom(String key, int value) {
    final previous = read(key);
    if (previous == null) return null;
    switch (key) {
      case 'cacheMiB':
        _cacheMiB = value < 0 ? 0 : value;
      case 'queuedSoft':
        _queuedSoft = value < 1 ? 1 : value;
      case 'queuedHard':
        _queuedHard =
            value < _queuedSoft ? _queuedSoft : value;
      case 'perPlayerInFlight':
        _perPlayerInFlight = value < 1 ? 1 : value;
      case 'p0Bonus':
        _p0Bonus = value < 0 ? 0 : value;
      case 'diskReads':
        _diskReads = value < 1 ? 1 : value;
      case 'diskFlushes':
        _diskFlushes = value < 1 ? 1 : value;
      case 'pregenTickets':
        _pregenTickets = value < 0 ? 0 : value;
      case 'pregenInFlightBusy':
        _pregenInFlightBusy = value < 0 ? 0 : value;
      case 'pregenInFlightIdle':
        _pregenInFlightIdle = value < 0 ? 0 : value;
      case 'inlineBudgetMicros':
        _inlineBudgetMicros = value < 0 ? 0 : value;
      case 'globalQueuedChunkBytes':
        _globalQueuedChunkBytes = value < 0 ? 0 : value;
      case 'writeQueueBytes':
        _writeQueueBytes = value < 0 ? 0 : value;
      case 'groupCommitChunks':
        _groupCommitChunks = value < 1 ? 1 : value;
      case 'groupCommitMillis':
        _groupCommitMillis = value < 0 ? 0 : value;
      case 'globalGenerationInFlight':
        _globalGenerationInFlight = value < 1 ? 1 : value;
      default:
        return null;
    }
    return previous;
  }

  int? read(String key) => switch (key) {
    'cacheMiB' => _cacheMiB,
    'queuedSoft' => _queuedSoft,
    'queuedHard' => _queuedHard,
    'perPlayerInFlight' => _perPlayerInFlight,
    'p0Bonus' => _p0Bonus,
    'diskReads' => _diskReads,
    'diskFlushes' => _diskFlushes,
    'pregenTickets' => _pregenTickets,
    'pregenInFlightBusy' => _pregenInFlightBusy,
    'pregenInFlightIdle' => _pregenInFlightIdle,
    'inlineBudgetMicros' => _inlineBudgetMicros,
    'globalQueuedChunkBytes' => _globalQueuedChunkBytes,
    'writeQueueBytes' => _writeQueueBytes,
    'groupCommitChunks' => _groupCommitChunks,
    'groupCommitMillis' => _groupCommitMillis,
    'globalGenerationInFlight' => _globalGenerationInFlight,
    _ => null,
  };

  Map<String, int> snapshot() => {
    for (final key in const [
      'cacheMiB',
      'queuedSoft',
      'queuedHard',
      'perPlayerInFlight',
      'p0Bonus',
      'diskReads',
      'diskFlushes',
      'pregenTickets',
      'pregenInFlightBusy',
      'pregenInFlightIdle',
      'inlineBudgetMicros',
      'globalQueuedChunkBytes',
      'writeQueueBytes',
      'groupCommitChunks',
      'groupCommitMillis',
      'globalGenerationInFlight',
    ])
      key: read(key)!,
  };
}
