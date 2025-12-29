import 'dart:typed_data';

class VarInt {
  VarInt._();

  static int read(Uint8List data, int offset) {
    int value = 0;
    int position = 0;
    int currentByte;

    while (true) {
      currentByte = data[offset];
      value |= (currentByte & 0x7F) << (position * 7);

      if ((currentByte & 0x80) == 0) {
        break;
      }

      offset++;
      position++;

      if (position >= 5) {
        throw Exception('VarInt is too long');
      }
    }

    return value;
  }

  static int write(Uint8List buffer, int offset, int value) {
    int position = 0;

    while (true) {
      int byte = value & 0x7F;
      value >>= 7;

      if (value != 0) {
        byte |= 0x80;
      }

      buffer[offset + position] = byte;
      position++;

      if (value == 0) {
        break;
      }

      if (position >= 5) {
        throw Exception('VarInt is too long');
      }
    }

    return position;
  }

  static int getSize(int value) {
    if (value < 0) {
      throw Exception('VarInt cannot be negative');
    }

    int size = 0;
    while (value != 0) {
      value >>= 7;
      size++;
    }

    return size == 0 ? 1 : size;
  }
}
