import 'dart:typed_data';

class PacketBuffer {
  Uint8List _data;
  int _readOffset = 0;
  int _writeOffset = 0;
  static const int _kInitialSize = 4096;
  static const int _kMaxSize = 2097152;

  PacketBuffer() : _data = Uint8List(_kInitialSize);

  int get available => _writeOffset - _readOffset;
  bool get isEmpty => _readOffset >= _writeOffset;

  void append(List<int> bytes) {
    final needed = _writeOffset + bytes.length;
    if (needed > _data.length) {
      _grow(needed);
    }
    _data.setRange(_writeOffset, _writeOffset + bytes.length, bytes);
    _writeOffset += bytes.length;
  }

  void _grow(int needed) {
    final newSize = _calculateNewSize(needed);
    final newData = Uint8List(newSize);
    final available = _writeOffset - _readOffset;
    newData.setRange(0, available, _data, _readOffset);
    _data = newData;
    _writeOffset = available;
    _readOffset = 0;
  }

  int _calculateNewSize(int needed) {
    int newSize = _data.length;
    while (newSize < needed && newSize < _kMaxSize) {
      newSize *= 2;
    }
    return newSize > _kMaxSize ? _kMaxSize : newSize;
  }

  Uint8List? tryReadPacket() {
    if (available < 1) return null;

    final result = _readVarInt();
    if (result == null) return null;

    final packetLength = result.value;
    final varIntSize = result.size;
    final totalSize = varIntSize + packetLength;

    if (packetLength > _kMaxSize || totalSize > available) {
      return null;
    }

    final packet = Uint8List(totalSize);
    packet.setRange(0, totalSize, _data, _readOffset);
    _readOffset += totalSize;

    if (_readOffset > _data.length ~/ 2 && _readOffset == _writeOffset) {
      _readOffset = 0;
      _writeOffset = 0;
    }

    return packet;
  }

  _VarIntResult? _readVarInt() {
    if (available < 1) return null;

    int value = 0;
    int position = 0;
    int offset = _readOffset;

    while (true) {
      if (offset >= _writeOffset) return null;

      final byte = _data[offset];
      value |= (byte & 0x7F) << (position * 7);

      if ((byte & 0x80) == 0) {
        return _VarIntResult(value: value, size: offset - _readOffset + 1);
      }

      offset++;
      position++;

      if (position >= 5) return null;
    }
  }

  void clear() {
    _readOffset = 0;
    _writeOffset = 0;
  }
}

class _VarIntResult {
  final int value;
  final int size;

  _VarIntResult({required this.value, required this.size});
}
