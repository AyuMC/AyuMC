import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'budgets.dart';
import 'demand.dart';
import 'key.dart';
import 'pipeline.dart';
import 'storage.dart';
import 'ticket.dart';

enum PregenShape { square, disk }

enum PregenState { running, paused, cancelled, done }

final class PregenTask {
  PregenTask({
    required this.id,
    required this.worldId,
    required this.centerX,
    required this.centerZ,
    required this.radius,
    required this.shape,
    this.state = PregenState.running,
    this.cursor = 0,
    this.processed = 0,
    this.skipped = 0,
    this.failed = 0,
    this.regenMismatched = false,
    DateTime? started,
    DateTime? updated,
  }) : started = started ?? DateTime.now(),
       updated = updated ?? DateTime.now();

  final String id;
  final String worldId;
  final int centerX;
  final int centerZ;
  final int radius;
  final PregenShape shape;
  PregenState state;
  int cursor;
  int processed;
  int skipped;
  int failed;
  bool regenMismatched;
  DateTime started;
  DateTime updated;
  final Set<ChunkKey> inflight = {};

  int get total {
    final span = radius * 2 + 1;
    if (shape == PregenShape.square) return span * span;
    var n = 0;
    for (var dz = -radius; dz <= radius; dz++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dz * dz <= radius * radius) n++;
      }
    }
    return n;
  }

  ChunkKey? keyAt(int index) {
    var i = 0;
    for (var dz = -radius; dz <= radius; dz++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (shape == PregenShape.disk && dx * dx + dz * dz > radius * radius) {
          continue;
        }
        if (i == index) {
          return ChunkKey(worldId: worldId, x: centerX + dx, z: centerZ + dz);
        }
        i++;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'worldId': worldId,
        'centerX': centerX,
        'centerZ': centerZ,
        'radius': radius,
        'shape': shape.name,
        'state': state.name,
        'cursor': cursor,
        'processed': processed,
        'skipped': skipped,
        'failed': failed,
        'regenMismatched': regenMismatched,
        'startedMs': started.millisecondsSinceEpoch,
        'updatedMs': updated.millisecondsSinceEpoch,
      };

  static PregenTask fromJson(Map<String, Object?> json) {
    return PregenTask(
      id: json['id'] as String,
      worldId: json['worldId'] as String? ?? ChunkKey.overworld,
      centerX: json['centerX'] as int,
      centerZ: json['centerZ'] as int,
      radius: json['radius'] as int,
      shape: PregenShape.values.firstWhere(
        (s) => s.name == json['shape'],
        orElse: () => PregenShape.square,
      ),
      state: PregenState.values.firstWhere(
        (s) => s.name == json['state'],
        orElse: () => PregenState.paused,
      ),
      cursor: json['cursor'] as int? ?? 0,
      processed: json['processed'] as int? ?? 0,
      skipped: json['skipped'] as int? ?? 0,
      failed: json['failed'] as int? ?? 0,
      regenMismatched: json['regenMismatched'] == true,
      started: DateTime.fromMillisecondsSinceEpoch(json['startedMs'] as int? ?? 0),
      updated: DateTime.fromMillisecondsSinceEpoch(json['updatedMs'] as int? ?? 0),
    );
  }
}

final class PregenService {
  PregenService({
    required this.directory,
    required this.pipeline,
    required this.demand,
    required this.storage,
    required this.generatorId,
    required this.generatorVersion,
    this.workingSet = 16,
  });

  final Directory directory;
  final ChunkPipeline pipeline;
  final ChunkDemand demand;
  final ChunkStorage storage;
  final String generatorId;
  final int generatorVersion;
  final int workingSet;
  final Map<String, PregenTask> tasks = {};
  final Object holder = Object();
  final List<DateTime> _completions = [];
  Timer? _persistTimer;
  Future<void> _persistChain = Future<void>.value();

  Future<void> load() async {
    if (!directory.existsSync()) return;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (entity.path.endsWith('.tmp')) continue;
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map) continue;
      final task = PregenTask.fromJson(decoded.cast<String, Object?>());
      tasks[task.id] = task;
      if (task.state == PregenState.running) {
        pipeline.addPregenHolder(holder);
      }
    }
    _armPersist();
  }

  PregenTask start({
    required int centerX,
    required int centerZ,
    required int radius,
    PregenShape shape = PregenShape.square,
    String? id,
  }) {
    final task = PregenTask(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      worldId: demand.worldId,
      centerX: centerX,
      centerZ: centerZ,
      radius: radius,
      shape: shape,
    );
    tasks[task.id] = task;
    pipeline.addPregenHolder(holder);
    _armPersist();
    unawaited(_persist(task));
    return task;
  }

  void pause([String? id]) {
    for (final task in _select(id)) {
      if (task.state == PregenState.running) task.state = PregenState.paused;
      task.updated = DateTime.now();
      unawaited(_persist(task));
    }
    _syncTickets();
    _releaseIfIdle();
  }

  void resume([String? id]) {
    for (final task in _select(id)) {
      if (task.state == PregenState.paused) task.state = PregenState.running;
      task.updated = DateTime.now();
      pipeline.addPregenHolder(holder);
      unawaited(_persist(task));
    }
  }

  void cancel([String? id]) {
    for (final task in _select(id)) {
      task.state = PregenState.cancelled;
      task.inflight.clear();
      task.updated = DateTime.now();
      unawaited(_persist(task));
    }
    _syncTickets();
    _releaseIfIdle();
  }

  Future<void> pump() async {
    if (pipeline.probe.pressure != Pressure.normal) {
      demand.clear(holder);
      return;
    }
    var lookups = 0;
    for (final task in tasks.values) {
      if (task.state != PregenState.running) continue;
      while (task.inflight.length < workingSet &&
          task.cursor < task.total &&
          lookups < 32) {
        final key = task.keyAt(task.cursor);
        task.cursor++;
        if (key == null) continue;
        lookups++;
        final lookup = await storage.lookup(key);
        if (_skip(task, lookup)) {
          task.skipped++;
          task.processed++;
          _noteCompletion();
          continue;
        }
        task.inflight.add(key);
      }
      if (task.cursor >= task.total && task.inflight.isEmpty) {
        task.state = PregenState.done;
        task.updated = DateTime.now();
        unawaited(_persist(task));
      }
    }
    _syncTickets();
    _releaseIfIdle();
  }

  void onResident(ChunkKey key) {
    for (final task in tasks.values) {
      if (!task.inflight.remove(key)) continue;
      task.processed++;
      task.updated = DateTime.now();
      _noteCompletion();
      pipeline.removeTicket(holder, key);
    }
    _syncTickets();
  }

  String statusText() {
    if (tasks.isEmpty) return 'no pregen tasks';
    final lines = <String>[];
    for (final task in tasks.values) {
      final remaining = task.total - task.processed;
      final rate = _rate();
      final eta = rate > 0 && task.state == PregenState.running
          ? '${(remaining / rate).toStringAsFixed(1)}s'
          : '-';
      lines.add(
        '${task.id} ${task.state.name} ${task.processed}/${task.total} '
        'skipped ${task.skipped} failed ${task.failed} '
        'rate ${rate.toStringAsFixed(1)}/s eta $eta',
      );
    }
    return lines.join('\n');
  }

  Future<void> close() async {
    _persistTimer?.cancel();
    demand.clear(holder);
    pipeline.removePregenHolder(holder);
    for (final task in tasks.values) {
      await _persist(task);
    }
    await _persistChain;
  }

  bool _skip(PregenTask task, ChunkLookup lookup) {
    if (lookup.kind != ChunkLookupKind.hit) return false;
    if (lookup.generatorId != generatorId || !lookup.finalized) return false;
    if (lookup.generatorVersion == generatorVersion) return true;
    return !task.regenMismatched;
  }

  void _syncTickets() {
    final keys = <ChunkKey, TicketReason>{};
    for (final task in tasks.values) {
      if (task.state != PregenState.running) continue;
      for (final key in task.inflight) {
        keys[key] = TicketReason.p4;
      }
    }
    if (keys.isEmpty) {
      demand.clear(holder);
    } else {
      demand.setKeys(holder, keys);
    }
  }

  Iterable<PregenTask> _select(String? id) {
    if (id == null) return tasks.values;
    final task = tasks[id];
    return task == null ? const [] : [task];
  }

  void _noteCompletion() {
    final now = DateTime.now();
    _completions.add(now);
    _completions.removeWhere(
      (time) => now.difference(time) > const Duration(seconds: 5),
    );
  }

  double _rate() {
    if (_completions.length < 2) return 0;
    final span = _completions.last.difference(_completions.first).inMilliseconds;
    if (span <= 0) return 0;
    return _completions.length * 1000 / span;
  }

  void _releaseIfIdle() {
    if (tasks.values.every((t) => t.state != PregenState.running)) {
      pipeline.removePregenHolder(holder);
    }
  }

  void _armPersist() {
    _persistTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      for (final task in tasks.values) {
        unawaited(_persist(task));
      }
    });
  }

  Future<void> _persist(PregenTask task) {
    _persistChain = _persistChain.then((_) => _writeTask(task));
    return _persistChain;
  }

  Future<void> _writeTask(PregenTask task) async {
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '${task.id}.json'));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('${jsonEncode(task.toJson())}\n');
    if (await file.exists()) await file.delete();
    if (await tmp.exists()) await tmp.rename(file.path);
  }
}
