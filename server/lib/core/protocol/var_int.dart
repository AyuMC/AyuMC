import 'dart:typed_data';

/// Result of reading a VarInt, containing both the value and the actual size.
class VarIntResult {
  final int value;
  final int size;

  VarIntResult(this.value, this.size);
}

class VarInt {
  VarInt._();

  /// Reads a VarInt from the buffer at the given offset.
  /// Returns both the value and the actual number of bytes consumed.
  static VarIntResult read(Uint8List data, int offset) {
    int value = 0;
    int position = 0;

    while (true) {
      // CRITICAL: Check bounds before accessing array
      if (offset + position >= data.length) {
        throw Exception(
          'VarInt read out of bounds: offset ${offset + position} >= length ${data.length}',
        );
      }

      final currentByte = data[offset + position];
      value |= (currentByte & 0x7F) << (position * 7);

      if ((currentByte & 0x80) == 0) {
        break;
      }

      position++;

      if (position >= 5) {
        throw Exception('VarInt is too long (max 5 bytes)');
      }
    }

    return VarIntResult(value, position + 1);
  }

  static int write(Uint8List buffer, int offset, int value) {
    // Validate value is non-negative
    if (value < 0) {
      throw Exception('VarInt cannot be negative: $value');
    }

    int position = 0;

    // CRITICAL: Check bounds before each write
    // We need at least 1 byte, but could need up to 5 bytes
    if (offset >= buffer.length) {
      throw Exception(
        'VarInt write out of bounds: offset $offset >= buffer length ${buffer.length}',
      );
    }

    while (true) {
      // Check bounds before writing each byte
      if (offset + position >= buffer.length) {
        throw Exception(
          'VarInt write out of bounds: need ${offset + position + 1} bytes, have ${buffer.length}',
        );
      }

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
        throw Exception('VarInt is too long (max 5 bytes)');
      }
    }

    return position;
  }

  static int getSize(int value) {
    if (value < 0) {
      throw Exception('VarInt cannot be negative');
    }

    // Calculate size by simulating write operation EXACTLY
    // This MUST match the logic in write() byte-for-byte
    // CRITICAL: Must match write() logic exactly:
    // 1. Write byte (value & 0x7F)
    // 2. Shift value >>= 7
    // 3. Increment position
    // 4. Check if value == 0, break
    int position = 0;
    int tempValue = value;

    while (true) {
      // Simulate: byte = tempValue & 0x7F (not used, but part of logic)
      tempValue >>= 7;
      position++;

      if (tempValue == 0) {
        break;
      }

      if (position >= 5) {
        throw Exception('VarInt size exceeds maximum (5 bytes)');
      }
    }

    return position;
  }

  /// Encodes a value to a VarInt byte array.
  static Uint8List encode(int value) {
    final size = getSize(value);
    final buffer = Uint8List(size);
    write(buffer, 0, value);
    return buffer;
  }

  /// Decodes VarInt size from buffer at offset.
  /// Returns the number of bytes used by the VarInt.
  static int decodeSize(Uint8List data, int offset) {
    int position = 0;
    while (position < 5 && offset + position < data.length) {
      if ((data[offset + position] & 0x80) == 0) {
        return position + 1;
      }
      position++;
    }
    return position;
  }
}
