import 'dart:typed_data';

import 'errors.dart';

/// Kind of a protocol frame. The numeric value is what travels on the wire.
enum FrameKind {
  request(1),
  response(2),
  notification(3);

  const FrameKind(this.wireValue);

  final int wireValue;

  static FrameKind? fromWire(int value) => switch (value) {
    1 => FrameKind.request,
    2 => FrameKind.response,
    3 => FrameKind.notification,
    _ => null,
  };
}

/// Fixed wire layout: `[u32 length][u8 kind][u32 id][payload]`, big-endian.
///
/// `length` counts everything after the length prefix.
abstract final class FrameLayout {
  static const lengthPrefixBytes = 4;
  static const headerBytes = 5;
  static const maxId = 0xFFFFFFFF;
}

/// A complete frame. [payload] is owned by the frame and never aliases the
/// decoder buffer.
final class Frame {
  const Frame(this.kind, this.id, this.payload);

  final FrameKind kind;
  final int id;
  final Uint8List payload;
}

/// Encodes a frame into a single contiguous buffer.
Uint8List encodeFrame(FrameKind kind, int id, Uint8List payload) {
  assert(id >= 0 && id <= FrameLayout.maxId, 'frame id out of range: $id');
  final total =
      FrameLayout.lengthPrefixBytes + FrameLayout.headerBytes + payload.length;
  final out = Uint8List(total);
  final view = ByteData.view(out.buffer);
  view.setUint32(0, FrameLayout.headerBytes + payload.length);
  out[FrameLayout.lengthPrefixBytes] = kind.wireValue;
  view.setUint32(FrameLayout.lengthPrefixBytes + 1, id);
  out.setRange(FrameLayout.lengthPrefixBytes + FrameLayout.headerBytes, total,
      payload);
  return out;
}

/// Incremental frame parser.
///
/// Feed arbitrary byte chunks with [addChunk]; complete frames are returned
/// as soon as they are available. Violations throw [FrameFormatException]
/// and leave the decoder unusable.
final class FrameDecoder {
  FrameDecoder({required this.maxFrameBytes})
    : assert(maxFrameBytes >= FrameLayout.headerBytes);

  /// Upper bound for `kind + id + payload` of a single frame.
  final int maxFrameBytes;

  Uint8List _buffer = Uint8List(1024);
  int _start = 0;
  int _end = 0;
  bool _failed = false;

  int get bufferedBytes => _end - _start;

  List<Frame> addChunk(List<int> chunk) {
    if (_failed) {
      throw const FrameFormatException('decoder is in a failed state');
    }
    _append(chunk);
    final frames = <Frame>[];
    try {
      while (true) {
        final available = _end - _start;
        if (available < FrameLayout.lengthPrefixBytes) break;
        final length = _readUint32(_start);
        if (length < FrameLayout.headerBytes) {
          throw FrameFormatException(
              'frame length $length is below the ${FrameLayout.headerBytes}-byte header');
        }
        if (length > maxFrameBytes) {
          throw FrameFormatException(
              'frame length $length exceeds the limit of $maxFrameBytes bytes');
        }
        if (available < FrameLayout.lengthPrefixBytes + length) break;
        final kindByte = _buffer[_start + FrameLayout.lengthPrefixBytes];
        final kind = FrameKind.fromWire(kindByte);
        if (kind == null) {
          throw FrameFormatException('unknown frame kind $kindByte');
        }
        final id = _readUint32(_start + FrameLayout.lengthPrefixBytes + 1);
        final payloadStart =
            _start + FrameLayout.lengthPrefixBytes + FrameLayout.headerBytes;
        final payloadEnd = _start + FrameLayout.lengthPrefixBytes + length;
        frames.add(Frame(kind, id, _buffer.sublist(payloadStart, payloadEnd)));
        _start = payloadEnd;
      }
    } on FrameFormatException {
      _failed = true;
      rethrow;
    }
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return frames;
  }

  void _append(List<int> chunk) {
    final needed = _end - _start + chunk.length;
    if (_buffer.length - _end < chunk.length) {
      if (needed > _buffer.length) {
        var capacity = _buffer.length * 2;
        while (capacity < needed) {
          capacity *= 2;
        }
        final grown = Uint8List(capacity);
        grown.setRange(0, _end - _start, _buffer, _start);
        _buffer = grown;
      } else {
        _buffer.setRange(0, _end - _start, _buffer, _start);
      }
      _end -= _start;
      _start = 0;
    }
    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  int _readUint32(int offset) =>
      (_buffer[offset] << 24) |
      (_buffer[offset + 1] << 16) |
      (_buffer[offset + 2] << 8) |
      _buffer[offset + 3];
}
