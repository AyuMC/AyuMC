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

  int get remaining => _data.length - _offset;
  int get offset => _offset;
  set offset(int value) => _offset = value;
}
