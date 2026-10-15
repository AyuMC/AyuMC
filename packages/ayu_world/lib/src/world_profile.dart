import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'generator.dart';
import 'key.dart';
import 'terrain.dart';

final class WorldProfile {
  WorldProfile({
    required this.worldId,
    required this.seed,
    required this.generatorId,
    required this.generatorVersion,
    this.storage = 'ayur',
  });

  final String worldId;
  final String seed;
  final String generatorId;
  final int generatorVersion;
  final String storage;

  int get seedValue => int.tryParse(seed) ?? 0;

  Map<String, Object?> toJson() => {
        'worldId': worldId,
        'seed': seed,
        'generatorId': generatorId,
        'generatorVersion': generatorVersion,
        'storage': storage,
      };

  static Future<WorldProfile> loadOrCreate(
    Directory worldDir,
    ChunkGenerator generator, {
    String storage = 'ayur',
    String seed = '0',
  }) async {
    await worldDir.create(recursive: true);
    final file = File(p.join(worldDir.path, 'world.json'));
    if (file.existsSync()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return WorldProfile(
          worldId: decoded['worldId'] as String? ?? p.basename(worldDir.path),
          seed: '${decoded['seed'] ?? seed}',
          generatorId: decoded['generatorId'] as String? ?? generator.id,
          generatorVersion: decoded['generatorVersion'] as int? ?? generator.version,
          storage: decoded['storage'] as String? ?? storage,
        );
      }
    }
    final profile = WorldProfile(
      worldId: p.basename(worldDir.path),
      seed: seed,
      generatorId: generator.id,
      generatorVersion: generator.version,
      storage: storage,
    );
    await file.writeAsString('${jsonEncode(profile.toJson())}\n');
    return profile;
  }

  static WorldProfile? peek(Directory worldDir) {
    final file = File(p.join(worldDir.path, 'world.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return WorldProfile(
        worldId: decoded['worldId'] as String? ?? p.basename(worldDir.path),
        seed: '${decoded['seed'] ?? '0'}',
        generatorId: decoded['generatorId'] as String? ?? '',
        generatorVersion: decoded['generatorVersion'] as int? ?? 0,
        storage: decoded['storage'] as String? ?? 'ayur',
      );
    } on FormatException {
      return null;
    }
  }

  /// Generator recorded in [worldDir], or [TerrainGeneratorV1] for a new world.
  static ChunkGenerator generatorFor(Directory worldDir) {
    final existing = peek(worldDir);
    if (existing == null) return TerrainGeneratorV1();
    final generator = generatorById(existing.generatorId);
    if (generator == null) {
      throw UnknownGeneratorException(existing.generatorId, worldDir.path);
    }
    return generator;
  }

  /// Stored seed wins. A new world uses [configured] or a fresh 31-bit value.
  static String seedFor(Directory worldDir, {String? configured}) {
    final existing = peek(worldDir);
    if (existing != null) return existing.seed;
    if (configured != null && configured.isNotEmpty) return configured;
    final n = Random.secure().nextInt(0x7fffffff);
    return '${n == 0 ? 1 : n}';
  }
}

final class UnknownGeneratorException implements Exception {
  UnknownGeneratorException(this.generatorId, this.worldDir);

  final String generatorId;
  final String worldDir;

  @override
  String toString() =>
      'unknown generator "$generatorId" in $worldDir; the world file was not changed';
}

final class ChunkRuntimeConfig {
  const ChunkRuntimeConfig({
    this.workers = -1,
    this.maxWorkers = 8,
    this.cacheMiB = 256,
    this.sendSliceBytes = 256 * 1024,
  });

  /// `-1` automatic, `0` inline, positive a fixed isolate count.
  final int workers;
  final int maxWorkers;
  final int cacheMiB;
  final int sendSliceBytes;

  static ChunkRuntimeConfig fromServerJson(Map<String, Object?> decoded) {
    final chunks = decoded['chunks'];
    if (chunks is! Map) return const ChunkRuntimeConfig();
    final workers = chunks['workers'];
    final maxWorkers = chunks['maxWorkers'];
    final cache = chunks['cacheMiB'];
    final send = chunks['sendSliceBytes'];
    return ChunkRuntimeConfig(
      workers: chunks.containsKey('workers')
          ? (workers is int ? workers : -1)
          : -1,
      maxWorkers: maxWorkers is int && maxWorkers > 0 ? maxWorkers : 8,
      cacheMiB: cache is int && cache > 0 ? cache : 256,
      sendSliceBytes: send is int && send > 0 ? send : 256 * 1024,
    );
  }

  static String? worldSeed(Map<String, Object?> decoded) {
    final world = decoded['world'];
    if (world is Map && world['seed'] != null) return '${world['seed']}';
    return null;
  }
}

Directory worldDirectory(Directory worlds, [String worldId = ChunkKey.overworld]) =>
    Directory(p.join(worlds.path, worldId));
