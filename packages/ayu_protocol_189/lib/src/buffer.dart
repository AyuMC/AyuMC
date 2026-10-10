import 'dart:convert';
import 'dart:typed_data';

/// A cursor over a growable byte buffer with Minecraft's VarInt, unsigned
/// short and length-prefixed UTF-8 string encodings.
final class PacketBuffer {
  PacketBuffer() : _bytes = Uint8List(64);

  Uint8List _bytes;
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  void add(List<int> chunk) {
    _ensure(_end + chunk.length);
    _bytes.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Reads a complete frame (`VarInt length` + that many bytes) or returns
  /// null when more bytes are needed. The length prefix is not part of the
  /// returned packet bytes.
  Uint8List? readFrame({int maxFrameBytes = 1 << 20}) {
    final saved = _start;
    final length = _tryVarInt();
    if (length == null) {
      _start = saved;
      return null;
    }
    if (length < 0 || length > maxFrameBytes) {
      throw PacketFormatException('packet length $length exceeds $maxFrameBytes');
    }
    if (length > _end - _start) {
      _start = saved;
      return null;
    }
    final frame = _bytes.sublist(_start, _start + length);
    _start += length;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return frame;
  }

  int readVarInt() {
    final value = _tryVarInt();
    if (value == null) throw const PacketFormatException('truncated VarInt');
    return value;
  }

  int readUnsignedShort() {
    if (_end - _start < 2) throw const PacketFormatException('truncated unsigned short');
    final value = (_bytes[_start] << 8) | _bytes[_start + 1];
    _start += 2;
    return value;
  }

  String readString({int maxBytes = 32767}) {
    final length = readVarInt();
    if (length < 0 || length > maxBytes) {
      throw PacketFormatException('string length $length exceeds $maxBytes');
    }
    if (_end - _start < length) throw const PacketFormatException('truncated string');
    final bytes = _bytes.sublist(_start, _start + length);
    _start += length;
    try {
      return utf8Strict.decode(bytes);
    } on FormatException {
      throw const PacketFormatException('string is not valid UTF-8');
    }
  }

  int readLong() {
    if (_end - _start < 8) throw const PacketFormatException('truncated long');
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | _bytes[_start + i];
    }
    _start += 8;
    return value;
  }

  void _ensure(int needed) {
    if (needed <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _end - _start, _bytes, _start);
    _end -= _start;
    _start = 0;
    _bytes = grown;
  }

  int? _tryVarInt() {
    var value = 0;
    var shift = 0;
    for (var i = 0; i < 5; i++) {
      if (_start >= _end) {
        _start -= i;
        return null;
      }
      final byte = _bytes[_start++];
      value |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
    throw const PacketFormatException('VarInt is longer than 5 bytes');
  }
}

final class PacketFormatException implements Exception {
  const PacketFormatException(this.message);

  final String message;

  @override
  String toString() => 'PacketFormatException: $message';
}

/// Strict UTF-8. Dart's default decoder replaces bad sequences.
final utf8Strict = Utf8Codec(allowMalformed: false);

/// Encodes one uncompressed 1.8.9 packet: `VarInt(length) VarInt(id) payload`.
Uint8List encodePacket(int id, [List<int> payload = const []]) {
  final idBytes = encodeVarInt(id);
  final length = encodeVarInt(idBytes.length + payload.length);
  return Uint8List.fromList([...length, ...idBytes, ...payload]);
}

Uint8List encodeVarInt(int value) {
  final bytes = <int>[];
  var rest = value;
  do {
    var next = rest & 0x7F;
    rest >>= 7;
    if (rest != 0) next |= 0x80;
    bytes.add(next);
  } while (rest != 0);
  return Uint8List.fromList(bytes);
}

Uint8List encodeString(String value) {
  final bytes = utf8Strict.encode(value);
  return Uint8List.fromList([...encodeVarInt(bytes.length), ...bytes]);
}

Uint8List encodeUnsignedShort(int value) => Uint8List.fromList([(value >> 8) & 0xFF, value & 0xFF]);

Uint8List encodeLong(int value) {
  final bytes = Uint8List(8);
  var rest = value;
  for (var i = 7; i >= 0; i--) {
    bytes[i] = rest & 0xFF;
    rest >>= 8;
  }
  return bytes;
}
