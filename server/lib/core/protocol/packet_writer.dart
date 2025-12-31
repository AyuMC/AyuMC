import 'dart:typed_data';
import '../network/optimization/memory_pool.dart';
import 'var_int.dart';

class PacketWriter {
  final List<int> _buffer = [];
  static final BufferMemoryPool _memoryPool = BufferMemoryPool();

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

  void writeDouble(double value) {
    final data = ByteData(8);
    data.setFloat64(0, value, Endian.big);
    _buffer.addAll(data.buffer.asUint8List());
  }

  void writeFloat(double value) {
    final data = ByteData(4);
    data.setFloat32(0, value, Endian.big);
    _buffer.addAll(data.buffer.asUint8List());
  }

  /// Writes a UUID as 16 bytes (most significant bits first, then least significant).
  ///
  /// Format: 2 longs (8 bytes each)
  void writeUuid(String uuidString) {
    // Parse UUID string: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    final parts = uuidString.split('-');
    if (parts.length != 5) {
      throw ArgumentError('Invalid UUID format: $uuidString');
    }

    // Combine parts into hex string
    final hexString = parts.join();
    if (hexString.length != 32) {
      throw ArgumentError('Invalid UUID format: $uuidString');
    }

    // Parse as two longs using BigInt to handle large numbers
    final mostSignificantBig = BigInt.parse(
      hexString.substring(0, 16),
      radix: 16,
    );
    final leastSignificantBig = BigInt.parse(
      hexString.substring(16, 32),
      radix: 16,
    );

    // Convert BigInt to int64 (signed, but we treat as unsigned)
    // For most significant: take lower 64 bits
    final mostSignificant = mostSignificantBig.toUnsigned(64).toInt();
    final leastSignificant = leastSignificantBig.toUnsigned(64).toInt();

    writeLong(mostSignificant);
    writeLong(leastSignificant);
  }

  /// Writes a position as a packed 64-bit value.
  ///
  /// X: 26 bits, Z: 26 bits, Y: 12 bits
  void writePosition(int x, int y, int z) {
    final packed =
        ((x & 0x3FFFFFF) << 38) | ((z & 0x3FFFFFF) << 12) | (y & 0xFFF);
    writeLong(packed);
  }

  Uint8List toBytes() {
    // Use memory pool for buffer allocation (reduces GC pressure)
    final buffer = _memoryPool.acquire(_buffer.length);
    for (int i = 0; i < _buffer.length; i++) {
      buffer[i] = _buffer[i];
    }
    final result = Uint8List.fromList(buffer.sublist(0, _buffer.length));
    _memoryPool.release(buffer);
    return result;
  }
}
