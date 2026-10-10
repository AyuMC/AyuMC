import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart';

/// Structural limits enforced while parsing an archive.
final class ZipLimits {
  const ZipLimits({
    this.maxEntries = 10000,
    this.maxCentralDirectoryBytes = 8 << 20,
    this.maxEntryBytes = 128 << 20,
  });

  final int maxEntries;
  final int maxCentralDirectoryBytes;

  /// Upper bound for both compressed and uncompressed size of one entry.
  final int maxEntryBytes;
}

/// Thrown for structurally invalid archives. [unsupported] marks valid but
/// unsupported features (encryption, ZIP64, multi-disk, exotic methods).
class ZipFormatException implements Exception {
  const ZipFormatException(this.message, {this.unsupported = false});

  final String message;
  final bool unsupported;

  @override
  String toString() => 'ZipFormatException: $message';
}

enum ZipLimitKind { entries, centralDirectory, entrySize }

/// A well-formed archive that exceeds a configured [ZipLimits] value.
final class ZipLimitException extends ZipFormatException {
  const ZipLimitException(this.kind, super.message);

  final ZipLimitKind kind;
}

final class ZipEntry {
  const ZipEntry._({
    required this.name,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  /// Raw name as stored (UTF-8 decoded), `/`-separated.
  final String name;

  /// 0 = stored, 8 = deflate.
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  bool get isDirectory => name.endsWith('/');
}

/// Minimal, strict ZIP reader: central-directory driven, stored and deflate
/// only, every size and checksum verified. Supports exactly what the `.ayu`
/// writer produces plus what common tools emit for such content.
final class ZipReader {
  ZipReader._(this._file, this.entries, this._centralDirectoryOffset, this.limits);

  final RandomAccessFile _file;
  final int _centralDirectoryOffset;
  final ZipLimits limits;
  final List<ZipEntry> entries;

  static const _zip64LocatorSignature = 0x07064b50;
  static const _centralSignature = 0x02014b50;
  static const _localSignature = 0x04034b50;
  static const _eocdLength = 22;
  static const _maxCommentLength = 0xFFFF;
  static const _centralFixedLength = 46;
  static const _localFixedLength = 30;

  static Future<ZipReader> open(File file, {ZipLimits limits = const ZipLimits()}) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      if (length < _eocdLength) {
        throw const ZipFormatException('file is too small to be a ZIP archive');
      }
      final tailLength = length < _eocdLength + _maxCommentLength
          ? length
          : _eocdLength + _maxCommentLength;
      await raf.setPosition(length - tailLength);
      final tail = await _readExactly(raf, tailLength);
      final eocdInTail = _findEocd(tail);
      if (eocdInTail < 0) {
        throw const ZipFormatException('end of central directory record not found');
      }
      final eocdPosition = length - tailLength + eocdInTail;
      final eocd = ByteData.sublistView(tail, eocdInTail);
      final diskNumber = eocd.getUint16(4, Endian.little);
      final centralDisk = eocd.getUint16(6, Endian.little);
      final entriesOnDisk = eocd.getUint16(8, Endian.little);
      final entriesTotal = eocd.getUint16(10, Endian.little);
      final centralSize = eocd.getUint32(12, Endian.little);
      final centralOffset = eocd.getUint32(16, Endian.little);

      if (diskNumber != 0 || centralDisk != 0 || entriesOnDisk != entriesTotal) {
        throw const ZipFormatException('multi-disk archives are not supported', unsupported: true);
      }
      if (entriesTotal == 0xFFFF || centralSize == 0xFFFFFFFF || centralOffset == 0xFFFFFFFF) {
        throw const ZipFormatException('ZIP64 archives are not supported', unsupported: true);
      }
      if (eocdInTail >= 20) {
        final locator = ByteData.sublistView(tail, eocdInTail - 20, eocdInTail);
        if (locator.getUint32(0, Endian.little) == _zip64LocatorSignature) {
          throw const ZipFormatException('ZIP64 archives are not supported', unsupported: true);
        }
      }
      if (entriesTotal > limits.maxEntries) {
        throw ZipLimitException(ZipLimitKind.entries,
            'archive declares $entriesTotal entries; the limit is ${limits.maxEntries}');
      }
      if (centralSize > limits.maxCentralDirectoryBytes) {
        throw ZipLimitException(ZipLimitKind.centralDirectory,
            'central directory of $centralSize bytes exceeds ${limits.maxCentralDirectoryBytes}');
      }
      if (centralOffset + centralSize != eocdPosition) {
        throw const ZipFormatException('central directory does not end at the end-of-central-directory record');
      }

      await raf.setPosition(centralOffset);
      final central = await _readExactly(raf, centralSize);
      final entries = _parseCentralDirectory(central, entriesTotal, centralOffset, limits);
      return ZipReader._(raf, List.unmodifiable(entries), centralOffset, limits);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  Future<void> close() => _file.close();

  /// Reads one entry fully into memory after verifying size and CRC.
  Future<Uint8List> readEntry(ZipEntry entry) async {
    final collector = _BytesCollector();
    await readEntryTo(entry, collector);
    return collector.takeBytes();
  }

  /// Streams the inflated bytes of [entry] into [sink], verifying the
  /// declared uncompressed size and CRC-32. The sink is not closed.
  Future<void> readEntryTo(ZipEntry entry, Sink<List<int>> sink) async {
    if (entry.compressedSize > limits.maxEntryBytes || entry.uncompressedSize > limits.maxEntryBytes) {
      throw ZipLimitException(ZipLimitKind.entrySize,
          'entry "${entry.name}" exceeds the per-entry limit of ${limits.maxEntryBytes} bytes');
    }
    await _file.setPosition(entry.localHeaderOffset);
    final local = await _readExactly(_file, _localFixedLength);
    final header = ByteData.sublistView(local);
    if (header.getUint32(0, Endian.little) != _localSignature) {
      throw ZipFormatException('entry "${entry.name}" has a corrupt local header');
    }
    final nameLength = header.getUint16(26, Endian.little);
    final extraLength = header.getUint16(28, Endian.little);
    final dataStart = entry.localHeaderOffset + _localFixedLength + nameLength + extraLength;
    if (dataStart + entry.compressedSize > _centralDirectoryOffset) {
      throw ZipFormatException('entry "${entry.name}" data overlaps the central directory');
    }
    await _file.setPosition(dataStart);
    final compressed = await _readExactly(_file, entry.compressedSize);

    final verifier = _VerifyingSink(sink, entry);
    switch (entry.method) {
      case 0:
        verifier.add(compressed);
      case 8:
        final inflater = ZLibDecoder(raw: true).startChunkedConversion(verifier);
        const chunk = 64 << 10;
        for (var offset = 0; offset < compressed.length; offset += chunk) {
          final end = offset + chunk < compressed.length ? offset + chunk : compressed.length;
          inflater.add(Uint8List.sublistView(compressed, offset, end));
        }
        inflater.close();
      default:
        throw ZipFormatException('compression method ${entry.method} is not supported', unsupported: true);
    }
    verifier.verifyComplete();
  }

  static int _findEocd(Uint8List tail) {
    for (var pos = tail.length - _eocdLength; pos >= 0; pos--) {
      if (tail[pos] != 0x50 || tail[pos + 1] != 0x4B || tail[pos + 2] != 0x05 || tail[pos + 3] != 0x06) {
        continue;
      }
      final commentLength = tail[pos + 20] | (tail[pos + 21] << 8);
      if (pos + _eocdLength + commentLength == tail.length) return pos;
    }
    return -1;
  }

  static List<ZipEntry> _parseCentralDirectory(
      Uint8List central, int expectedEntries, int centralOffset, ZipLimits limits) {
    final entries = <ZipEntry>[];
    final view = ByteData.sublistView(central);
    var offset = 0;
    while (entries.length < expectedEntries) {
      if (offset + _centralFixedLength > central.length) {
        throw const ZipFormatException('central directory is truncated');
      }
      if (view.getUint32(offset, Endian.little) != _centralSignature) {
        throw const ZipFormatException('central directory entry has a bad signature');
      }
      final flags = view.getUint16(offset + 8, Endian.little);
      final method = view.getUint16(offset + 10, Endian.little);
      final crc = view.getUint32(offset + 16, Endian.little);
      final compressedSize = view.getUint32(offset + 20, Endian.little);
      final uncompressedSize = view.getUint32(offset + 24, Endian.little);
      final nameLength = view.getUint16(offset + 28, Endian.little);
      final extraLength = view.getUint16(offset + 30, Endian.little);
      final commentLength = view.getUint16(offset + 32, Endian.little);
      final disk = view.getUint16(offset + 34, Endian.little);
      final localOffset = view.getUint32(offset + 42, Endian.little);

      if (flags & 0x0001 != 0 || flags & 0x0040 != 0) {
        throw const ZipFormatException('encrypted entries are not supported', unsupported: true);
      }
      if (method != 0 && method != 8) {
        throw ZipFormatException('compression method $method is not supported', unsupported: true);
      }
      if (compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF) {
        throw const ZipFormatException('ZIP64 entries are not supported', unsupported: true);
      }
      if (disk != 0) {
        throw const ZipFormatException('multi-disk entries are not supported', unsupported: true);
      }
      if (method == 0 && compressedSize != uncompressedSize) {
        throw const ZipFormatException('stored entry has mismatching sizes');
      }
      if (localOffset >= centralOffset) {
        throw const ZipFormatException('entry local header lies inside the central directory');
      }
      final nameStart = offset + _centralFixedLength;
      final nameEnd = nameStart + nameLength;
      final entryEnd = nameEnd + extraLength + commentLength;
      if (entryEnd > central.length) {
        throw const ZipFormatException('central directory entry is truncated');
      }
      final String name;
      try {
        name = const Utf8Decoder(allowMalformed: false).convert(central, nameStart, nameEnd);
      } on FormatException {
        throw const ZipFormatException('entry name is not valid UTF-8');
      }
      entries.add(ZipEntry._(
        name: name,
        method: method,
        crc32: crc,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localOffset,
      ));
      offset = entryEnd;
    }
    if (offset != central.length) {
      throw const ZipFormatException('central directory contains trailing bytes');
    }
    return entries;
  }

  static Future<Uint8List> _readExactly(RandomAccessFile file, int count) async {
    final bytes = await file.read(count);
    if (bytes.length != count) {
      throw const ZipFormatException('unexpected end of file');
    }
    return bytes;
  }
}

final class _BytesCollector implements Sink<List<int>> {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) => _builder.add(data);

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Counts bytes, tracks CRC-32 and refuses to exceed the declared size, so a
/// lying header can never inflate past its own claim.
final class _VerifyingSink implements Sink<List<int>> {
  _VerifyingSink(this._target, this._entry);

  final Sink<List<int>> _target;
  final ZipEntry _entry;
  int _count = 0;
  int _crc = 0;

  @override
  void add(List<int> data) {
    _count += data.length;
    if (_count > _entry.uncompressedSize) {
      throw ZipFormatException(
          'entry "${_entry.name}" inflates beyond its declared ${_entry.uncompressedSize} bytes');
    }
    _crc = Crc32.update(_crc, data);
    _target.add(data);
  }

  @override
  void close() {}

  void verifyComplete() {
    if (_count != _entry.uncompressedSize) {
      throw ZipFormatException(
          'entry "${_entry.name}" produced $_count bytes, declared ${_entry.uncompressedSize}');
    }
    if (_crc != _entry.crc32) {
      throw ZipFormatException('entry "${_entry.name}" failed its CRC-32 check');
    }
  }
}
