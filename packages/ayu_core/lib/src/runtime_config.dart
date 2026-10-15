import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Configuration file schema version.
///
/// Version 2 adds `configVersion`, `compressionThreshold`, and the streaming
/// budget block under `chunks`. A file without a version is a version 1 file
/// and is migrated in memory; the migration is written back atomically the
/// next time the engine persists.
const currentConfigVersion = 2;

/// Where a setting takes effect.
enum ConfigScope {
  /// The owning engine component is reconfigured while the server runs.
  live,

  /// Only connections that log in after the change are affected. Protocol 47
  /// negotiates transport compression during login and has no in-play
  /// renegotiation.
  newConnections,

  /// Stored and validated now, applied on the next server start.
  restart,
}

enum ConfigKind { integer, toggle, choice }

/// One configuration setting. Only settings the running code actually reads
/// appear here; the configuration screen renders exactly this list.
final class ConfigSpec {
  const ConfigSpec({
    required this.path,
    required this.category,
    required this.label,
    required this.description,
    required this.kind,
    required this.defaultValue,
    this.min,
    this.max,
    this.unit = '',
    this.scope = ConfigScope.live,
    this.choices = const [],
  });

  /// Dotted key. For writable settings this is also the JSON location, so
  /// `chunks.sendSliceBytes` is written under the `chunks` object.
  final String path;
  final String category;
  final String label;
  final String description;
  final ConfigKind kind;
  final int defaultValue;
  final int? min;
  final int? max;
  final String unit;
  final ConfigScope scope;

  /// Labels for [ConfigKind.choice], indexed by value.
  final List<String> choices;

  Map<String, Object?> toJson() => {
    'path': path,
    'category': category,
    'label': label,
    'description': description,
    'kind': kind.name,
    'default': defaultValue,
    'min': min,
    'max': max,
    'unit': unit,
    'scope': scope.name,
    'choices': choices,
  };
}

/// Every knob the engine can actually apply.
///
/// Ranges are safety limits, not measured targets. The starting values and the
/// measurements behind them are in the chunk streaming benchmark results.
const configSpecs = <ConfigSpec>[
  // A. General
  ConfigSpec(
    path: 'viewChunks',
    category: 'General',
    label: 'Server view-distance cap',
    description:
        'Largest chunk radius this server streams to a player. The client '
        'settings slider can ask for less; it can never raise this cap.',
    kind: ConfigKind.integer,
    defaultValue: 6,
    min: 2,
    max: 16,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'port',
    category: 'General',
    label: 'Minecraft port',
    description: 'Listener port. Changing it restarts the listener.',
    kind: ConfigKind.integer,
    defaultValue: 25565,
    min: 1,
    max: 65535,
    scope: ConfigScope.restart,
  ),
  ConfigSpec(
    path: 'entityUpdateMillis',
    category: 'General',
    label: 'Entity update interval',
    description:
        'How often the newest accepted pose is sent to viewers. Zero sends on '
        'the packet that changed it.',
    kind: ConfigKind.integer,
    defaultValue: 50,
    min: 0,
    max: 1000,
    unit: 'ms',
    scope: ConfigScope.restart,
  ),
  ConfigSpec(
    path: 'visibility',
    category: 'General',
    label: 'Player visibility mode',
    description:
        'distance uses the view cap; all makes every session visible to every '
        'other session and is meant for tests.',
    kind: ConfigKind.choice,
    defaultValue: 0,
    choices: ['distance', 'all'],
    scope: ConfigScope.restart,
  ),

  // B. Chunk Streaming
  ConfigSpec(
    path: 'chunks.sendSliceBytes',
    category: 'Chunk Streaming',
    label: 'Per-player send slice',
    description:
        'Bytes handed to one socket per delivery tick. One packet is always '
        'allowed even when it exceeds the slice.',
    kind: ConfigKind.integer,
    defaultValue: 256 * 1024,
    min: 16 * 1024,
    max: 4 * 1024 * 1024,
    unit: 'bytes',
  ),
  ConfigSpec(
    path: 'chunks.sendIntervalMillis',
    category: 'Chunk Streaming',
    label: 'Delivery tick interval',
    description:
        'How often a chunk slice is handed to each socket. Smaller sends '
        'smoother motion, larger spends less CPU on scheduling.',
    kind: ConfigKind.integer,
    defaultValue: 50,
    min: 5,
    max: 500,
    unit: 'ms',
  ),
  ConfigSpec(
    path: 'chunks.globalSendBytes',
    category: 'Chunk Streaming',
    label: 'Global send budget',
    description:
        'Bytes per delivery tick shared by every connection. A player joining '
        'cannot spend another player\u2019s share of the budget.',
    kind: ConfigKind.integer,
    defaultValue: 2 * 1024 * 1024,
    min: 64 * 1024,
    max: 64 * 1024 * 1024,
    unit: 'bytes',
  ),
  ConfigSpec(
    path: 'chunks.perPlayerPendingChunks',
    category: 'Chunk Streaming',
    label: 'Pending chunks per player',
    description:
        'Most resident columns queued for one client and not yet sent. It '
        'bounds memory for a slow client without dropping the view.',
    kind: ConfigKind.integer,
    defaultValue: 512,
    min: 16,
    max: 4096,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.perPlayerQueuedBytes',
    category: 'Chunk Streaming',
    label: 'Pending bytes per player',
    description: 'Byte ceiling for the same pending queue.',
    kind: ConfigKind.integer,
    defaultValue: 8 * 1024 * 1024,
    min: 64 * 1024,
    max: 64 * 1024 * 1024,
    unit: 'bytes',
  ),
  ConfigSpec(
    path: 'chunks.perPlayerInFlight',
    category: 'Chunk Streaming',
    label: 'Loads per player',
    description:
        'Storage reads and generations in flight for one player. Spawn-critical '
        'work may exceed it by the p0 bonus.',
    kind: ConfigKind.integer,
    defaultValue: 16,
    min: 1,
    max: 64,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.p0Bonus',
    category: 'Chunk Streaming',
    label: 'Spawn-critical bonus',
    description:
        'Extra in-flight slots only the spawn-supporting ring may use, so a '
        'crowded player cannot starve a spawn.',
    kind: ConfigKind.integer,
    defaultValue: 9,
    min: 0,
    max: 64,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.queuedSoft',
    category: 'Chunk Streaming',
    label: 'Queue soft cap',
    description:
        'Above this queue depth only player-required work is accepted; '
        'prefetch and pre-generation wait.',
    kind: ConfigKind.integer,
    defaultValue: 4096,
    min: 16,
    max: 65536,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.queuedHard',
    category: 'Chunk Streaming',
    label: 'Queue hard cap',
    description:
        'No new work is queued above this depth. Must be at least the soft cap.',
    kind: ConfigKind.integer,
    defaultValue: 8192,
    min: 32,
    max: 131072,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.globalQueuedChunkBytes',
    category: 'Chunk Streaming',
    label: 'Queued byte ceiling',
    description:
        'Payload bytes the scheduler may hold across every player before it '
        'starts deferring background work.',
    kind: ConfigKind.integer,
    defaultValue: 32 * 1024 * 1024,
    min: 1024 * 1024,
    max: 512 * 1024 * 1024,
    unit: 'bytes',
  ),
  ConfigSpec(
    path: 'chunks.pregenTickets',
    category: 'Chunk Streaming',
    label: 'Pre-generation tickets',
    description:
        'Chunk columns a running pre-generation task may hold at once.',
    kind: ConfigKind.integer,
    defaultValue: 16,
    min: 0,
    max: 1024,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.pregenInFlightBusy',
    category: 'Chunk Streaming',
    label: 'Pre-generation loads while busy',
    description:
        'Background loads allowed while players have outstanding work. Zero '
        'gives players all capacity.',
    kind: ConfigKind.integer,
    defaultValue: 1,
    min: 0,
    max: 32,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.pregenInFlightIdle',
    category: 'Chunk Streaming',
    label: 'Pre-generation loads while idle',
    description: 'Background loads allowed when no player work is outstanding.',
    kind: ConfigKind.integer,
    defaultValue: 2,
    min: 0,
    max: 32,
    unit: 'chunks',
  ),

  // C. Generation and Workers
  ConfigSpec(
    path: 'chunks.workers',
    category: 'Generation and Workers',
    label: 'Generation workers',
    description:
        '-1 automatic, 0 inline on the engine isolate, or a fixed number of '
        'isolates. Shrinking drains workers without cancelling their work.',
    kind: ConfigKind.integer,
    defaultValue: -1,
    min: -1,
    max: 64,
  ),
  ConfigSpec(
    path: 'chunks.maxWorkers',
    category: 'Generation and Workers',
    label: 'Maximum workers',
    description: 'Upper bound automatic mode and fixed requests are clamped to.',
    kind: ConfigKind.integer,
    defaultValue: 8,
    min: 1,
    max: 64,
  ),
  ConfigSpec(
    path: 'chunks.globalGenerationInFlight',
    category: 'Generation and Workers',
    label: 'Global generation concurrency',
    description:
        'Generations in flight across every player. Spawn-critical work may '
        'exceed it by the p0 bonus.',
    kind: ConfigKind.integer,
    defaultValue: 64,
    min: 1,
    max: 256,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.workerSubmitQueue',
    category: 'Generation and Workers',
    label: 'Pending generation queue',
    description:
        'Generation jobs a full worker pool may hold before submissions are '
        'refused and re-queued for a later tick.',
    kind: ConfigKind.integer,
    defaultValue: 256,
    min: 1,
    max: 4096,
    unit: 'jobs',
  ),
  ConfigSpec(
    path: 'chunks.inlineBudgetMicros',
    category: 'Generation and Workers',
    label: 'Inline budget per tick',
    description:
        'Microseconds of inline generation per engine tick before work is '
        'deferred to the next tick.',
    kind: ConfigKind.integer,
    defaultValue: 2000,
    min: 0,
    max: 50000,
    unit: 'µs',
  ),
  ConfigSpec(
    path: 'chunks.transferableBytes',
    category: 'Generation and Workers',
    label: 'Worker transfer buffer',
    description:
        'Reusable transfer buffer per worker result. Applies to workers '
        'started after the change.',
    kind: ConfigKind.integer,
    defaultValue: 32 * 1024,
    min: 4096,
    max: 1024 * 1024,
    unit: 'bytes',
    scope: ConfigScope.restart,
  ),

  // D. Memory and Storage
  ConfigSpec(
    path: 'chunks.cacheMiB',
    category: 'Memory and Storage',
    label: 'Chunk cache',
    description:
        'Resident payload and packet budget. Unreferenced columns are evicted '
        'above it.',
    kind: ConfigKind.integer,
    defaultValue: 256,
    min: 16,
    max: 4096,
    unit: 'MiB',
  ),
  ConfigSpec(
    path: 'chunks.diskReads',
    category: 'Memory and Storage',
    label: 'Outstanding disk reads',
    description: 'Storage lookups in flight across the pipeline.',
    kind: ConfigKind.integer,
    defaultValue: 8,
    min: 1,
    max: 64,
    unit: 'reads',
  ),
  ConfigSpec(
    path: 'chunks.diskFlushes',
    category: 'Memory and Storage',
    label: 'Concurrent region flushes',
    description:
        'Region-log flushes allowed at once. One writer serializes batches; '
        'this caps overlap.',
    kind: ConfigKind.integer,
    defaultValue: 2,
    min: 1,
    max: 8,
  ),
  ConfigSpec(
    path: 'chunks.writeQueueBytes',
    category: 'Memory and Storage',
    label: 'Dirty write queue',
    description:
        'Dirty payload bytes allowed before generation pauses to let storage '
        'catch up.',
    kind: ConfigKind.integer,
    defaultValue: 32 * 1024 * 1024,
    min: 1024 * 1024,
    max: 512 * 1024 * 1024,
    unit: 'bytes',
  ),
  ConfigSpec(
    path: 'chunks.groupCommitChunks',
    category: 'Memory and Storage',
    label: 'Group commit size',
    description: 'Dirty columns that trigger a storage flush immediately.',
    kind: ConfigKind.integer,
    defaultValue: 32,
    min: 1,
    max: 4096,
    unit: 'chunks',
  ),
  ConfigSpec(
    path: 'chunks.groupCommitMillis',
    category: 'Memory and Storage',
    label: 'Group commit interval',
    description: 'Longest a dirty column waits before storage gets it.',
    kind: ConfigKind.integer,
    defaultValue: 50,
    min: 0,
    max: 10000,
    unit: 'ms',
  ),

  // E. Network
  ConfigSpec(
    path: 'compressionThreshold',
    category: 'Network',
    label: 'Compression threshold',
    description:
        '-1 disables transport compression. 0 compresses every packet; a '
        'positive value compresses packets of at least that size. Applies to '
        'connections that log in from now on.',
    kind: ConfigKind.integer,
    defaultValue: 256,
    min: -1,
    max: 65536,
    unit: 'bytes',
    scope: ConfigScope.newConnections,
  ),
];

/// One validated change.
final class ConfigApplyResult {
  ConfigApplyResult({
    required this.path,
    required this.value,
    required this.previous,
    required this.revision,
    required this.scope,
    required this.pendingPersistence,
  });

  final String path;
  final int value;
  final int previous;
  final int revision;
  final ConfigScope scope;
  final bool pendingPersistence;

  bool get changed => value != previous;

  Map<String, Object?> toJson() => {
    'path': path,
    'value': value,
    'previous': previous,
    'revision': revision,
    'scope': scope.name,
    'pendingPersistence': pendingPersistence,
    'changed': changed,
  };
}

/// Authoritative runtime configuration.
///
/// The engine owns this object. The manager reads the schema and current
/// values over the control protocol and sends validated changes; it never
/// writes the file and never keeps a second effective copy.
///
/// Persistence is coalesced: rapid arrow-key edits apply in memory at once and
/// reach disk at most every [persistDelay], with a guaranteed final write on
/// [flush]. Writes are atomic (temporary file plus rename) and keep one
/// previous file as `server.json.prev`.
final class RuntimeConfigService {
  RuntimeConfigService({
    required this.file,
    this.persistDelay = const Duration(milliseconds: 400),
    void Function(String message)? log,
  }) : _log = log;

  final File file;
  final Duration persistDelay;
  final void Function(String message)? _log;

  final Map<String, int> _values = {};
  final Map<String, Object?> _json = {};
  final Map<String, Future<void> Function(int value)> _appliers = {};
  final Set<String> _dirtyPaths = {};

  /// Read-only facts shown in the Diagnostics category.
  Map<String, Object?> readOnlyFacts = {};

  int revision = 0;
  String? configError;
  Timer? _persistTimer;
  Future<void> _persistChain = Future<void>.value();
  bool _loaded = false;

  /// Set when the file held the legacy default of 10 chunks without a schema
  /// version. The value is kept; the screen offers a one-action switch to 6.
  int? legacyViewChunks;

  bool get hasPendingPersistence => _dirtyPaths.isNotEmpty;

  bool get writable => configError == null;

  int value(String path) => _values[path] ?? _defaultFor(path);

  /// Raw value at a dotted JSON path. Used for keys that are not settings,
  /// such as `world.seed`, which the engine may read but never rewrites.
  Object? raw(String path) {
    Object? cursor = _json;
    for (final part in path.split('.')) {
      if (cursor is! Map) return null;
      cursor = cursor[part];
    }
    return cursor;
  }

  ConfigSpec? spec(String path) {
    for (final item in configSpecs) {
      if (item.path == path) return item;
    }
    return null;
  }

  /// Registers the component that applies one path. A path without an applier
  /// is stored and validated but only takes effect on the next start, and its
  /// spec must say so.
  void on(String path, FutureOr<void> Function(int value) applier) {
    _appliers[path] = (value) async => applier(value);
  }

  Future<void> load() async {
    _json.clear();
    _values.clear();
    configError = null;
    legacyViewChunks = null;
    final versioned = <String, Object?>{};
    if (await file.exists()) {
      final text = await file.readAsString();
      final Object? decoded;
      try {
        decoded = text.trim().isEmpty ? null : jsonDecode(text);
      } on FormatException catch (error) {
        configError =
            '${file.path} is not valid JSON (${error.message}). Fix or remove '
            'it; the engine will not overwrite a file it cannot parse and is '
            'running on defaults.';
        _log?.call(configError!);
        _applyDefaults();
        _loaded = true;
        _schedulePersist();
        return;
      }
      if (decoded is Map) versioned.addAll(decoded.cast<String, Object?>());
    } else {
      // New installation: defaults are written on the first persist so the
      // file shows the version and every effective value.
      _dirtyPaths.add('*');
    }
    _json.addAll(versioned);
    final declaredVersion = _json['configVersion'];
    final legacyFile = declaredVersion is! int;
    final explicitView = _readInt(_json, 'viewChunks');
    if (legacyFile && explicitView == 10) {
      legacyViewChunks = 10;
      _log?.call(
        'viewChunks is still the legacy default of 10. The balanced default '
        'for new installations is 6; the configuration screen offers a '
        'one-action switch. The value is left untouched until you decide.',
      );
    }
    for (final item in configSpecs) {
      final stored = _readInt(_json, item.path);
      _values[item.path] =
          stored == null ? item.defaultValue : _clamp(item, stored);
      // Missing keys get written on the next persist so the file stays
      // self-describing for the settings this version added.
      if (stored == null) _dirtyPaths.add(item.path);
    }
    final soft = _values['chunks.queuedSoft']!;
    final hard = _values['chunks.queuedHard']!;
    if (hard < soft) {
      _values['chunks.queuedHard'] = soft;
      _dirtyPaths.add('chunks.queuedHard');
    }
    if (legacyFile) _dirtyPaths.add('*');
    _loaded = true;
    _schedulePersist();
  }

  /// Schema plus current values plus read-only facts. The manager renders this
  /// directly; there is no second copy anywhere else.
  Map<String, Object?> describe() => {
    'version': currentConfigVersion,
    'file': file.path,
    'revision': revision,
    'pendingPersistence': hasPendingPersistence,
    'writable': writable,
    'configError': configError,
    'legacyViewChunks': legacyViewChunks,
    'categories': [
      for (final name in const [
        'General',
        'Chunk Streaming',
        'Generation and Workers',
        'Memory and Storage',
        'Network',
      ])
        name,
    ],
    'specs': [for (final item in configSpecs) item.toJson()],
    'values': {for (final item in configSpecs) item.path: value(item.path)},
    'readOnly': readOnlyFacts,
  };

  /// Validates and applies one change.
  ///
  /// Order: validate, detect a concurrent revision, run the owning
  /// component's apply step (which may fail), commit the new effective value,
  /// then persist. A failure leaves the previous effective configuration in
  /// place.
  Future<ConfigApplyResult> apply({
    required String path,
    required int value,
    int? expectedRevision,
  }) async {
    if (!_loaded) throw ConfigException('configuration is not loaded yet');
    if (configError != null) {
      throw ConfigException(
        'configuration is read-only: $configError',
      );
    }
    final item = spec(path);
    if (item == null) {
      throw ConfigException('unknown setting "$path"');
    }
    if (expectedRevision != null && expectedRevision != revision) {
      throw ConfigException(
        'configuration changed while you were editing (expected revision '
        '$expectedRevision, current $revision). Refresh and try again.',
      );
    }
    final proposed = item.kind == ConfigKind.toggle
        ? (value == 0 ? 0 : 1)
        : _clamp(item, value);
    if (item.kind == ConfigKind.choice &&
        (proposed < 0 || proposed >= item.choices.length)) {
      throw ConfigException(
        '"${item.label}" must be one of ${item.choices.join(', ')}',
      );
    }
    _validateDependencies(path, proposed);
    final previous = value0(path);
    if (proposed == previous) {
      // Duplicate or no-op request: acknowledge without touching the revision.
      return ConfigApplyResult(
        path: path,
        value: proposed,
        previous: previous,
        revision: revision,
        scope: item.scope,
        pendingPersistence: hasPendingPersistence,
      );
    }
    if (item.scope != ConfigScope.restart) {
      final applier = _appliers[path];
      if (applier == null) {
        throw ConfigException(
          '"${item.label}" is marked live but no engine component registers an '
          'apply step for it; refusing to report a change that would not take '
          'effect.',
        );
      }
      try {
        await applier(proposed);
      } catch (error) {
        throw ConfigException(
          'could not apply "${item.label}": $error. The previous value is '
          'still in force.',
        );
      }
    }
    _values[path] = proposed;
    revision++;
    _dirtyPaths.add(path);
    _schedulePersist();
    return ConfigApplyResult(
      path: path,
      value: proposed,
      previous: previous,
      revision: revision,
      scope: item.scope,
      pendingPersistence: hasPendingPersistence,
    );
  }

  /// Effective value without clamping; used for reporting and rollback.
  int value0(String path) => _values[path] ?? _defaultFor(path);

  /// Persists now. Called on shutdown and by an explicit save.
  Future<void> flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_dirtyPaths.isEmpty) return _persistChain;
    return _enqueueWrite();
  }

  void _schedulePersist() {
    if (!writable || _dirtyPaths.isEmpty) return;
    _persistTimer ??= Timer(persistDelay, () {
      _persistTimer = null;
      if (_dirtyPaths.isEmpty) return;
      unawaited(_enqueueWrite());
    });
  }

  Future<void> _enqueueWrite() {
    final run = _persistChain.then((_) => _write());
    _persistChain = run.catchError((Object error) {
      _log?.call('configuration could not be written: $error');
    });
    return run;
  }

  Future<void> _write() async {
    if (!writable || _dirtyPaths.isEmpty) return;
    _json['configVersion'] = currentConfigVersion;
    for (final item in configSpecs) {
      _writeInt(_json, item.path, value(item.path));
    }
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final encoder = JsonEncoder.withIndent('  ');
    await temp.writeAsString('${encoder.convert(_json)}\n', flush: true);
    if (await file.exists()) {
      final previous = File('${file.path}.prev');
      await file.copy(previous.path);
    }
    await temp.rename(file.path);
    _dirtyPaths.clear();
  }

  void _applyDefaults() {
    for (final item in configSpecs) {
      _values[item.path] = item.defaultValue;
    }
  }

  int _defaultFor(String path) {
    final item = spec(path);
    if (item == null) throw ConfigException('unknown setting "$path"');
    return item.defaultValue;
  }

  int _clamp(ConfigSpec item, int value) {
    var result = value;
    final min = item.min;
    final max = item.max;
    if (min != null && result < min) result = min;
    if (max != null && result > max) result = max;
    return result;
  }

  void _validateDependencies(String path, int proposed) {
    if (path == 'chunks.queuedSoft' &&
        proposed > value0('chunks.queuedHard')) {
      throw ConfigException(
        'the queue soft cap cannot exceed the hard cap '
        '(${value0('chunks.queuedHard')}).',
      );
    }
    if (path == 'chunks.queuedHard' &&
        proposed < value0('chunks.queuedSoft')) {
      throw ConfigException(
        'the queue hard cap cannot be below the soft cap '
        '(${value0('chunks.queuedSoft')}).',
      );
    }
    if (path == 'chunks.pregenInFlightIdle' &&
        proposed < value0('chunks.pregenInFlightBusy')) {
      throw ConfigException(
        'the idle pre-generation limit cannot be below the busy limit '
        '(${value0('chunks.pregenInFlightBusy')}).',
      );
    }
  }

  static int? _readInt(Map<String, Object?> json, String path) {
    Object? cursor = json;
    for (final part in path.split('.')) {
      if (cursor is! Map) return null;
      cursor = cursor[part];
    }
    return cursor is int ? cursor : null;
  }

  static void _writeInt(Map<String, Object?> json, String path, int value) {
    final parts = path.split('.');
    var cursor = json;
    for (var i = 0; i < parts.length - 1; i++) {
      final next = cursor[parts[i]];
      if (next is Map<String, Object?>) {
        cursor = next;
      } else if (next is Map) {
        final cast = next.cast<String, Object?>();
        cursor[parts[i]] = cast;
        cursor = cast;
      } else {
        final created = <String, Object?>{};
        cursor[parts[i]] = created;
        cursor = created;
      }
    }
    cursor[parts.last] = value;
  }
}

final class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}
