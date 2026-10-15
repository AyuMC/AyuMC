import 'dart:typed_data';

import 'generator.dart';
import 'noise.dart';
import 'payload.dart';

/// Surface terrain for protocol 47. Caves, ores, trees, and structures are
/// not generated. Sky light is column-only: air is 15, each water block
/// reduces it by 2, and the first opaque block and everything below it are 0.
/// There is no horizontal light spread.
final class TerrainGeneratorV1 implements ChunkGenerator {
  TerrainGeneratorV1();

  static const idName = 'terrain_v1';
  static const seaLevel = 64;
  static const minHeight = 8;
  static const maxHeight = 128;
  static const stone = 1;
  static const grass = 2;
  static const dirt = 3;
  static const bedrock = 7;
  static const water = 9;
  static const sand = 12;
  static const biomeOcean = 0;
  static const biomePlains = 1;
  static const biomeBeach = 16;

  GradientNoise? _noise;
  int? _noiseSeed;

  static const SpawnPoint _placeholder = SpawnPoint(
    blockX: 8,
    blockY: seaLevel,
    blockZ: 8,
    feetX: 8.5,
    feetY: seaLevel + 1.0,
    feetZ: 8.5,
    levelType: 'default',
  );

  @override
  String get id => idName;

  @override
  int get version => 1;

  @override
  bool get heavy => true;

  @override
  bool get requiresNeighbors => false;

  @override
  SpawnPoint get spawn => _placeholder;

  GradientNoise _sampler(int seed) {
    if (_noise != null && _noiseSeed == seed) return _noise!;
    _noise = GradientNoise(seed);
    _noiseSeed = seed;
    return _noise!;
  }

  /// Surface height at an absolute block column. Always in `[minHeight, maxHeight]`.
  int heightAt(int seed, int worldX, int worldZ) {
    final noise = _sampler(seed);
    final wx = worldX.toDouble();
    final wz = worldZ.toDouble();
    const continental = 1.0;
    const hills = 0.45;
    const detail = 0.15;
    const weight = continental + hills + detail;
    final n =
        (noise.sample(wx / 512.0, wz / 512.0) * continental +
            noise.sample(wx / 128.0 + 19.2, wz / 128.0 - 7.1) * hills +
            noise.sample(wx / 32.0 - 3.4, wz / 32.0 + 11.8) * detail) /
        weight;
    final scaled = minHeight + ((n + 1) * 0.5 * (maxHeight - minHeight));
    final height = scaled.round();
    if (height < minHeight) return minHeight;
    if (height > maxHeight) return maxHeight;
    return height;
  }

  @override
  ChunkPayload generate({required int seed, required int x, required int z}) {
    final heights = Int16List(256);
    final biomes = Uint8List(ChunkPayload.biomeBytes);
    var highest = 0;
    for (var lz = 0; lz < 16; lz++) {
      for (var lx = 0; lx < 16; lx++) {
        final h = heightAt(seed, x * 16 + lx, z * 16 + lz);
        heights[(lz << 4) | lx] = h;
        final filled = h < seaLevel ? seaLevel : h;
        if (filled > highest) highest = filled;
        biomes[(lz << 4) | lx] = _biome(h);
      }
    }
    final topY = highest + 1;
    final sectionCount = (topY >> 4) + 1;
    final bitmask = (1 << sectionCount) - 1;
    final size = ChunkPayload.sectionBytes(true);
    final sections = Uint8List(sectionCount * size);
    for (var lz = 0; lz < 16; lz++) {
      for (var lx = 0; lx < 16; lx++) {
        final h = heights[(lz << 4) | lx];
        final sandy = _sandy(h);
        _writeBlock(sections, size, lx, 0, lz, bedrock);
        for (var y = 1; y <= h; y++) {
          final id = _columnBlock(y, h, sandy);
          _writeBlock(sections, size, lx, y, lz, id);
        }
        if (h < seaLevel) {
          for (var y = h + 1; y <= seaLevel; y++) {
            _writeBlock(sections, size, lx, y, lz, water);
          }
        }
        _columnSky(sections, size, lx, lz, topY, h);
      }
    }
    return ChunkPayload(
      primaryBitmask: bitmask,
      skylight: true,
      biomes: biomes,
      sections: sections,
    );
  }

  int _biome(int height) {
    if (height < seaLevel) return biomeOcean;
    if (_sandy(height)) return biomeBeach;
    return biomePlains;
  }

  bool _sandy(int height) => height <= seaLevel + 2;

  int _columnBlock(int y, int surface, bool sandy) {
    if (y == surface) return sandy ? sand : grass;
    if (y >= surface - 2) return sandy ? sand : dirt;
    return stone;
  }

  void _columnSky(
    Uint8List sections,
    int size,
    int lx,
    int lz,
    int topY,
    int surface,
  ) {
    var sky = 15;
    final last = (topY | 15);
    for (var y = last; y >= 0; y--) {
      final id = y == 0
          ? bedrock
          : y <= surface
          ? _columnBlock(y, surface, _sandy(surface))
          : (surface < seaLevel && y <= seaLevel ? water : 0);
      if (id == 0) {
        writeSkyLightNibble(sections, size, lx, y, lz, sky);
      } else if (id == water) {
        sky -= 2;
        if (sky < 0) sky = 0;
        writeSkyLightNibble(sections, size, lx, y, lz, sky);
      } else {
        sky = 0;
        writeSkyLightNibble(sections, size, lx, y, lz, 0);
      }
    }
  }
}

void _writeBlock(
  Uint8List sections,
  int size,
  int x,
  int y,
  int z,
  int id,
) {
  final offset = (y >> 4) * size;
  final index = offset + (((y & 15) << 8) | (z << 4) | x) * 2;
  final value = id << 4;
  sections[index] = value & 0xFF;
  sections[index + 1] = (value >> 8) & 0xFF;
}
