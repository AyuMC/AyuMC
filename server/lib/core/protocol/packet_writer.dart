import 'dart:typed_data';
import 'var_int.dart';

class PacketWriter {
  final List<int> _buffer = [];

  void writeVarInt(int value) {
    final size = VarInt.getSize(value);
    final bytes = Uint8List(size);
    VarInt.write(bytes, 0, value);
    _buffer.addAll(bytes);
  }

  void writeString(String value) {
    final bytes = value.codeUnits;
    writeVarInt(bytes.length);
    _buffer.addAll(bytes);
  }

  void writeUnsignedShort(int value) {
    _buffer.add((value >> 8) & 0xFF);
    _buffer.add(value & 0xFF);
  }

  void writeLong(int value) {
    for (int i = 7; i >= 0; i--) {
      _buffer.add((value >> (i * 8)) & 0xFF);
    }
  }

  void writeInt(int value) {
    for (int i = 3; i >= 0; i--) {
      _buffer.add((value >> (i * 8)) & 0xFF);
    }
  }

  void writeByte(int value) {
    _buffer.add(value & 0xFF);
  }

  void writeBool(bool value) {
    _buffer.add(value ? 1 : 0);
  }

  void writeBytes(Uint8List bytes) {
    _buffer.addAll(bytes);
  }

  Uint8List toBytes() => Uint8List.fromList(_buffer);
}
