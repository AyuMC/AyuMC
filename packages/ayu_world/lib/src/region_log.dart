import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'crc32.dart';
import 'key.dart';
import 'payload.dart';
import 'storage.dart';

/// Append-only region log (`AYUR`). The last valid record for a key wins.
///
/// [flush] and [close] call `RandomAccessFile.flush` before returning.
/// Bytes appended after the last flush can disappear if the process dies.
/// That is not a power-loss guarantee. On open, an AYUR version-1 header is
/// replayed until the first bad length, checksum, or body. That torn tail is
/// truncated and every earlier record stays readable. A file whose header is
/// not AYUR version 1 is left unchanged and lookups fail.
final class RegionLogStorage implements ChunkStorage {
  RegionLogStorage(
    this.root, {
    this.worldId = ChunkKey.overworld,
    this.groupCommitChunks = 32,
    this.groupCommit = const Duration(milliseconds: 50),
  });

  final Directory root;
  final String worldId;
  final int groupCommitChunks;
  final Duration groupCommit;
  final Map<String, _Region> _open = {};

  /// Region opens in flight, keyed by region id.
  ///
  /// A lookup and a store for the same region can overlap. Without this map
  /// both would construct a `_Region`, and the one that lost the assignment
  /// kept a `RandomAccessFile` that no flush or close could ever reach. On
  /// Windows that leaked handle also kept the region file from being deleted.
  final Map<String, Future<_Region>> _opening = {};
  int _pending = 0;

  Directory get _regionDir => Directory(p.join(root.path, 'region'));
  Directory get _quarantineDir => Directory(p.join(root.path, 'quarantine'));

  Future<void> open() async {
    await _regionDir.create(recursive: true);
    await _quarantineDir.create(recursive: true);
  }

  @override
  Future<ChunkLookup> lookup(ChunkKey key) async {
    final region = await _regionFor(key);
    final offset = region.index[key];
    if (offset == null) return const ChunkLookup.miss();
    final record = await region.readAt(offset);
    if (record == null) {
      return const ChunkLookup.corrupt(playerModified: false);
    }
    if (record.chunkX != key.x || record.chunkZ != key.z) {
      return ChunkLookup.corrupt(
        playerModified: record.playerModified,
        raw: record.payload,
      );
    }
    try {
      final payload = ChunkPayload.unpack(record.payload);
      return ChunkLookup.hit(
        payload: payload,
        generatorId: record.generatorId,
        generatorVersion: record.generatorVersion,
        regenerable: record.regenerable,
        playerModified: record.playerModified,
        finalized: record.finalized,
      );
    } on FormatException {
      return ChunkLookup.corrupt(
        playerModified: record.playerModified,
        raw: record.payload,
      );
    }
  }

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) async {
    final region = await _regionFor(key);
    await region.append(
      _LogRecord(
        chunkX: key.x,
        chunkZ: key.z,
        generatorId: generatorId,
        generatorVersion: generatorVersion,
        regenerable: regenerable,
        playerModified: playerModified,
        finalized: finalized,
        payload: payload.pack(),
      ),
    );
    _pending++;
    if (playerModified || _pending >= groupCommitChunks) {
      await flush();
    }
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) async {
    await _quarantineDir.create(recursive: true);
    final file = File(
      p.join(_quarantineDir.path, 'c.${key.x}.${key.z}.bin'),
    );
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> flush() async {
    for (final region in _open.values) {
      await region.flush();
    }
    _pending = 0;
  }

  @override
  Future<void> close() async {
    await flush();
    for (final region in _open.values) {
      await region.close();
    }
    _open.clear();
    _opening.clear();
  }

  Future<void> compact(ChunkKey sample) async {
    final region = await _regionFor(sample);
    await region.compact();
  }

  Future<_Region> _regionFor(ChunkKey key) {
    final id = '${regionCoord(key.x)}.${regionCoord(key.z)}';
    final existing = _open[id];
    if (existing != null) return Future<_Region>.value(existing);
    final pending = _opening[id];
    if (pending != null) return pending;
    final opening = _openRegion(key, id);
    _opening[id] = opening;
    return opening.whenComplete(() {
      if (identical(_opening[id], opening)) _opening.remove(id);
    });
  }

  Future<_Region> _openRegion(ChunkKey key, String id) async {
    if (_open.length >= 8) {
      final oldest = _open.keys.first;
      await _open.remove(oldest)?.close();
    }
    final region = _Region(
      _regionDir,
      regionCoord(key.x),
      regionCoord(key.z),
      worldId,
    );
    await region.open();
    _open[id] = region;
    return region;
  }
}

final class _LogRecord {
  _LogRecord({
    required this.chunkX,
    required this.chunkZ,
    required this.generatorId,
    required this.generatorVersion,
    required this.regenerable,
    required this.playerModified,
    required this.finalized,
    required this.payload,
  });

  final int chunkX;
  final int chunkZ;
  final String generatorId;
  final int generatorVersion;
  final bool regenerable;
  final bool playerModified;
  final bool finalized;
  final Uint8List payload;

  int get flags =>
      (regenerable ? 1 : 0) | (playerModified ? 2 : 0) | (finalized ? 4 : 0);

  Uint8List encodeBody() {
    final idBytes = utf8.encode(generatorId);
    final body = BytesBuilder(copy: false);
    final header = ByteData(4 + 4 + 1 + 2 + 1);
    header.setInt32(0, chunkX, Endian.little);
    header.setInt32(4, chunkZ, Endian.little);
    header.setUint8(8, flags);
    header.setUint16(9, generatorVersion, Endian.little);
    header.setUint8(11, idBytes.length);
    body.add(header.buffer.asUint8List());
    body.add(idBytes);
    body.add(payload);
    return body.takeBytes();
  }

  static _LogRecord? decodeBody(Uint8List body) {
    if (body.length < 12) return null;
    final data = ByteData.sublistView(body);
    final chunkX = data.getInt32(0, Endian.little);
    final chunkZ = data.getInt32(4, Endian.little);
    final flags = data.getUint8(8);
    final generatorVersion = data.getUint16(9, Endian.little);
    final idLen = data.getUint8(11);
    if (body.length < 12 + idLen) return null;
    final generatorId = utf8.decode(body.sublist(12, 12 + idLen));
    final payload = Uint8List.fromList(body.sublist(12 + idLen));
    return _LogRecord(
      chunkX: chunkX,
      chunkZ: chunkZ,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: flags & 1 != 0,
      playerModified: flags & 2 != 0,
      finalized: flags & 4 != 0,
      payload: payload,
    );
  }
}

final class _Region {
  _Region(this.dir, this.rx, this.rz, this.worldId);

  final Directory dir;
  final int rx;
  final int rz;
  final String worldId;
  final Map<ChunkKey, int> index = {};
  int generation = 1;
  RandomAccessFile? _file;
  int _length = 0;
  int liveBytes = 0;
  int fileBytes = 0;

  String get _base => 'r.$rx.$rz';
  File get _manifest => File(p.join(dir.path, '$_base.manifest'));
  File _logFile(int gen) => File(p.join(dir.path, '$_base.$gen.ayur'));

  Future<void> open() async {
    await dir.create(recursive: true);
    generation = await _readManifest();
    final file = _logFile(generation);
    if (!file.existsSync()) {
      await file.writeAsBytes(_header(), flush: true);
    }
    await _replay(file);
  }

  Future<int> _readManifest() async {
    if (!_manifest.existsSync()) return 1;
    final lines = await _manifest.readAsLines();
    var gen = 1;
    for (final line in lines) {
      final value = int.tryParse(line.trim());
      if (value != null && value > 0) gen = value;
    }
    return gen;
  }

  Uint8List _header() {
    final bytes = Uint8List(8);
    bytes.setRange(0, 4, ascii.encode('AYUR'));
    bytes[4] = 1;
    return bytes;
  }

  bool _supportedHeader(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x41 &&
      bytes[1] == 0x59 &&
      bytes[2] == 0x55 &&
      bytes[3] == 0x52 &&
      bytes[4] == 1;

  Future<void> _replay(File file) async {
    index.clear();
    liveBytes = 0;
    final bytes = await file.readAsBytes();
    fileBytes = bytes.length;
    var offset = 0;
    if (!_supportedHeader(bytes)) {
      throw RegionLogException(
        'region ${file.path} header is not AYUR version 1',
      );
    }
    offset = 8;
    var validEnd = offset;
    while (offset + 8 <= bytes.length) {
      final length =
          bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
      final crc =
          bytes[offset + 4] |
          (bytes[offset + 5] << 8) |
          (bytes[offset + 6] << 16) |
          (bytes[offset + 7] << 24);
      if (length <= 0 || length > ChunkPayload.maxPackedBytes) {
        break;
      }
      if (offset + 8 + length > bytes.length) {
        break;
      }
      final body = bytes.sublist(offset + 8, offset + 8 + length);
      if (Crc32.compute(body) != crc) {
        break;
      }
      final record = _LogRecord.decodeBody(Uint8List.fromList(body));
      if (record == null) break;
      final key = ChunkKey(
        worldId: worldId,
        x: record.chunkX,
        z: record.chunkZ,
      );
      index[key] = offset;
      liveBytes = index.length; // count, compaction uses index vs file size
      validEnd = offset + 8 + length;
      offset = validEnd;
    }
    _length = validEnd;
    if (validEnd < bytes.length) {
      final raf = await file.open(mode: FileMode.append);
      await raf.truncate(validEnd);
      await raf.flush();
      await raf.close();
    }
    fileBytes = _length;
  }

  Future<void> append(_LogRecord record) async {
    final body = record.encodeBody();
    final crc = Crc32.compute(body);
    final frame = Uint8List(8 + body.length);
    frame[0] = body.length & 0xFF;
    frame[1] = (body.length >> 8) & 0xFF;
    frame[2] = (body.length >> 16) & 0xFF;
    frame[3] = (body.length >> 24) & 0xFF;
    frame[4] = crc & 0xFF;
    frame[5] = (crc >> 8) & 0xFF;
    frame[6] = (crc >> 16) & 0xFF;
    frame[7] = (crc >> 24) & 0xFF;
    frame.setRange(8, frame.length, body);
    _file ??= await _logFile(generation).open(mode: FileMode.append);
    final file = _file;
    if (file == null) throw StateError('region is closed');
    final offset = _length;
    await file.writeFrom(frame);
    _length += frame.length;
    fileBytes = _length;
    final key = ChunkKey(
      worldId: worldId,
      x: record.chunkX,
      z: record.chunkZ,
    );
    index[key] = offset;
  }

  Future<_LogRecord?> readAt(int offset) async {
    final reader = await _logFile(generation).open(mode: FileMode.read);
    try {
      await reader.setPosition(offset);
      final header = Uint8List(8);
      if (await reader.readInto(header) < 8) return null;
      final length =
          header[0] | (header[1] << 8) | (header[2] << 16) | (header[3] << 24);
      if (length <= 0 || length > ChunkPayload.maxPackedBytes) return null;
      final body = Uint8List(length);
      if (await reader.readInto(body) < length) return null;
      final crc =
          header[4] | (header[5] << 8) | (header[6] << 16) | (header[7] << 24);
      if (Crc32.compute(body) != crc) return null;
      return _LogRecord.decodeBody(body);
    } finally {
      await reader.close();
    }
  }

  Future<void> flush() async {
    await _file?.flush();
    await _file?.close();
    _file = null;
  }

  Future<void> compact() async {
    final next = generation + 1;
    final dest = _logFile(next);
    final raf = await dest.open(mode: FileMode.write);
    await raf.writeFrom(_header());
    var cursor = 8;
    final rebuilt = <ChunkKey, int>{};
    for (final entry in index.entries) {
      final record = await readAt(entry.value);
      if (record == null) continue;
      final body = record.encodeBody();
      final crc = Crc32.compute(body);
      final frame = Uint8List(8 + body.length);
      frame[0] = body.length & 0xFF;
      frame[1] = (body.length >> 8) & 0xFF;
      frame[2] = (body.length >> 16) & 0xFF;
      frame[3] = (body.length >> 24) & 0xFF;
      frame[4] = crc & 0xFF;
      frame[5] = (crc >> 8) & 0xFF;
      frame[6] = (crc >> 16) & 0xFF;
      frame[7] = (crc >> 24) & 0xFF;
      frame.setRange(8, frame.length, body);
      await raf.writeFrom(frame);
      rebuilt[entry.key] = cursor;
      cursor += frame.length;
    }
    await raf.flush();
    await raf.close();
    await _manifest.writeAsString('$next\n', flush: true);
    await _file?.close();
    final old = _logFile(generation);
    generation = next;
    index
      ..clear()
      ..addAll(rebuilt);
    _length = cursor;
    fileBytes = cursor;
    _file = await dest.open(mode: FileMode.append);
    if (await old.exists()) await old.delete();
  }

  Future<void> close() async {
    await _file?.flush();
    await _file?.close();
    _file = null;
  }
}

/// The region file is not AYUR version 1. The bytes were not modified.
final class RegionLogException implements Exception {
  RegionLogException(this.message);

  final String message;

  @override
  String toString() => 'RegionLogException: $message';
}
