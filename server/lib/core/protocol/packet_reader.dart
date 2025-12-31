import 'dart:typed_data';
import 'var_int.dart';

class PacketReader {
  final Uint8List _data;
  int _offset = 0;

  PacketReader(this._data);

  int readVarInt() {
    final value = VarInt.read(_data, _offset);
    _offset += VarInt.getSize(value);
    return value;
  }

  String readString() {
    final length = readVarInt();
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return String.fromCharCodes(bytes);
  }

  int readUnsignedShort() {
    final value = (_data[_offset] << 8) | _data[_offset + 1];
    _offset += 2;
    return value;
  }

  int readLong() {
    int value = 0;
    for (int i = 0; i < 8; i++) {
      value = (value << 8) | (_data[_offset + i] & 0xFF);
    }
    _offset += 8;
    return value;
  }

  double readDouble() {
    final bytes = _data.sublist(_offset, _offset + 8);
    final byteData = ByteData.view(Uint8List.fromList(bytes).buffer);
    _offset += 8;
    return byteData.getFloat64(0, Endian.big);
  }

  double readFloat() {
    final bytes = _data.sublist(_offset, _offset + 4);
    final byteData = ByteData.view(Uint8List.fromList(bytes).buffer);
    _offset += 4;
    return byteData.getFloat32(0, Endian.big);
  }

  bool readBool() {
    final value = _data[_offset] != 0;
    _offset++;
    return value;
  }

  int readByte() {
    final value = _data[_offset];
    _offset++;
    return value;
  }

  int readUnsignedByte() {
    return readByte() & 0xFF;
  }

  Uint8List readBytes(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return bytes;
  }

  /// Reads a position as a packed 64-bit value.
  ///
  /// X: 26 bits, Z: 26 bits, Y: 12 bits
  /// Returns a map with x, y, z coordinates.
  Map<String, int> readPosition() {
    final packed = readLong();
    final x = (packed >> 38) & 0x3FFFFFF;
    final z = (packed >> 12) & 0x3FFFFFF;
    final y = packed & 0xFFF;
    // Sign extend if needed
    final xSigned = (x & 0x2000000) != 0 ? (x | 0xFC000000) : x;
    final zSigned = (z & 0x2000000) != 0 ? (z | 0xFC000000) : z;
    return {'x': xSigned, 'y': y, 'z': zSigned};
  }

  int get remaining => _data.length - _offset;
  bool get hasRemaining => _offset < _data.length;
  int get offset => _offset;
  set offset(int value) => _offset = value;
}
