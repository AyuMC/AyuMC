import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart';

/// Minimal deterministic ZIP writer: UTF-8 names, stored or deflate, fixed
/// timestamps. Entries must be added in the order they should appear.
final class ZipWriter {
  ZipWriter(this._sink, {this.compressionLevel = 6, DateTime? timestamp})
    : _dosTime = _toDosTime(timestamp ?? DateTime.utc(1980, 1, 1)),
      _dosDate = _toDosDate(timestamp ?? DateTime.utc(1980, 1, 1));

  final IOSink _sink;
  final int compressionLevel;
  final int _dosTime;
  final int _dosDate;
  final List<_CentralEntry> _central = [];
  final Set<String> _names = {};
  int _offset = 0;
  bool _finished = false;

  static const _localSignature = 0x04034b50;
  static const _centralSignature = 0x02014b50;
  static const _eocdSignature = 0x06054b50;
  static const _utf8Flag = 0x0800;
  static const _versionNeeded = 20;

  /// Adds a file entry. Compression is skipped when it would not shrink
  /// the data.
  void addFile(String name, Uint8List data, {bool compress = true}) {
    _checkOpen();
    if (name.isEmpty || name.endsWith('/')) {
      throw ArgumentError.value(name, 'name', 'must be a non-empty file name');
    }
    if (!_names.add(name)) {
      throw ArgumentError.value(name, 'name', 'duplicate entry');
    }
    final crc = Crc32.compute(data);
    var method = 0;
    var payload = data;
    if (compress && data.isNotEmpty) {
      final deflated = Uint8List.fromList(
          ZLibEncoder(raw: true, level: compressionLevel).convert(data));
      if (deflated.length < data.length) {
        method = 8;
        payload = deflated;
      }
    }
    final nameBytes = utf8.encode(name);
    final header = ByteData(30);
    header.setUint32(0, _localSignature, Endian.little);
    header.setUint16(4, _versionNeeded, Endian.little);
    header.setUint16(6, _utf8Flag, Endian.little);
    header.setUint16(8, method, Endian.little);
    header.setUint16(10, _dosTime, Endian.little);
    header.setUint16(12, _dosDate, Endian.little);
    header.setUint32(14, crc, Endian.little);
    header.setUint32(18, payload.length, Endian.little);
    header.setUint32(22, data.length, Endian.little);
    header.setUint16(26, nameBytes.length, Endian.little);
    header.setUint16(28, 0, Endian.little);

    _central.add(_CentralEntry(
      nameBytes: nameBytes,
      method: method,
      crc: crc,
      compressedSize: payload.length,
      uncompressedSize: data.length,
      localOffset: _offset,
    ));
    _write(header.buffer.asUint8List());
    _write(nameBytes);
    _write(payload);
  }

  /// Writes the central directory and end record, then flushes the sink.
  /// The sink itself is left open for the caller to close.
  Future<void> finish() async {
    _checkOpen();
    _finished = true;
    final centralStart = _offset;
    for (final entry in _central) {
      final header = ByteData(46);
      header.setUint32(0, _centralSignature, Endian.little);
      header.setUint16(4, _versionNeeded, Endian.little);
      header.setUint16(6, _versionNeeded, Endian.little);
      header.setUint16(8, _utf8Flag, Endian.little);
      header.setUint16(10, entry.method, Endian.little);
      header.setUint16(12, _dosTime, Endian.little);
      header.setUint16(14, _dosDate, Endian.little);
      header.setUint32(16, entry.crc, Endian.little);
      header.setUint32(20, entry.compressedSize, Endian.little);
      header.setUint32(24, entry.uncompressedSize, Endian.little);
      header.setUint16(28, entry.nameBytes.length, Endian.little);
      header.setUint16(30, 0, Endian.little);
      header.setUint16(32, 0, Endian.little);
      header.setUint16(34, 0, Endian.little);
      header.setUint16(36, 0, Endian.little);
      header.setUint32(38, 0, Endian.little);
      header.setUint32(42, entry.localOffset, Endian.little);
      _write(header.buffer.asUint8List());
      _write(entry.nameBytes);
    }
    final centralSize = _offset - centralStart;
    final eocd = ByteData(22);
    eocd.setUint32(0, _eocdSignature, Endian.little);
    eocd.setUint16(4, 0, Endian.little);
    eocd.setUint16(6, 0, Endian.little);
    eocd.setUint16(8, _central.length, Endian.little);
    eocd.setUint16(10, _central.length, Endian.little);
    eocd.setUint32(12, centralSize, Endian.little);
    eocd.setUint32(16, centralStart, Endian.little);
    eocd.setUint16(20, 0, Endian.little);
    _write(eocd.buffer.asUint8List());
    await _sink.flush();
  }

  void _write(List<int> bytes) {
    _sink.add(bytes);
    _offset += bytes.length;
    if (_offset > 0xFFFFFFFF || _central.length > 0xFFFF) {
      throw StateError('archive exceeds the non-ZIP64 size limits');
    }
  }

  void _checkOpen() {
    if (_finished) throw StateError('writer already finished');
  }

  static int _toDosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second >> 1);

  static int _toDosDate(DateTime t) {
    final year = t.year < 1980 ? 1980 : t.year;
    return ((year - 1980) << 9) | (t.month << 5) | t.day;
  }
}

final class _CentralEntry {
  const _CentralEntry({
    required this.nameBytes,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
  });

  final Uint8List nameBytes;
  final int method;
  final int crc;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
}
