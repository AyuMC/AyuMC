import 'dart:typed_data';
import 'var_int.dart';

class Packet {
  final int id;
  final Uint8List data;

  Packet({required this.id, required this.data});

  factory Packet.fromBytes(Uint8List bytes) {
    // CRITICAL: Validate buffer has minimum size before reading
    if (bytes.isEmpty) {
      throw Exception('Packet is empty');
    }

    // Read packet length VarInt
    if (bytes.length < 1) {
      throw Exception(
        'Packet too short: need at least 1 byte for length, got ${bytes.length}',
      );
    }
    final packetLength = VarInt.read(bytes, 0);
    final packetLengthSize = VarInt.getSize(packetLength);

    // Validate packet length is reasonable
    if (packetLength < 0 || packetLength > 2097152) {
      throw Exception(
        'Invalid packet length: $packetLength (must be 0-2097152)',
      );
    }

    // Read packet ID VarInt
    if (bytes.length < packetLengthSize + 1) {
      throw Exception(
        'Packet too short: need at least ${packetLengthSize + 1} bytes for packet ID, got ${bytes.length}',
      );
    }
    final packetId = VarInt.read(bytes, packetLengthSize);
    final packetIdSize = VarInt.getSize(packetId);

    final dataStart = packetLengthSize + packetIdSize;
    // CRITICAL: packetLength is the length of (packetId + data), not total bytes
    // So data ends at: packetLengthSize + packetLength
    // But we need to ensure we don't read beyond available bytes
    final dataEnd = packetLengthSize + packetLength;
    if (dataEnd > bytes.length) {
      throw Exception(
        'Packet length mismatch: expected $dataEnd bytes, got ${bytes.length}',
      );
    }
    final data = bytes.sublist(dataStart, dataEnd);

    return Packet(id: packetId, data: data);
  }

  Uint8List toBytes() {
    // Calculate packet ID size
    final packetIdSize = VarInt.getSize(id);

    // Packet length = packet ID size + data length
    // This is the length of the packet payload (ID + data), not including length VarInt
    final packetLength = packetIdSize + data.length;

    // Calculate packet length VarInt size
    final packetLengthSize = VarInt.getSize(packetLength);

    // Total buffer size = length VarInt + packet length
    final totalSize = packetLengthSize + packetLength;
    final buffer = Uint8List(totalSize);

    // Write packet length (VarInt) at offset 0
    final writtenLengthSize = VarInt.write(buffer, 0, packetLength);
    
    // Verify written size matches expected (critical for protocol correctness)
    if (writtenLengthSize != packetLengthSize) {
      throw Exception(
        'VarInt length size mismatch: expected $packetLengthSize bytes, wrote $writtenLengthSize bytes for value $packetLength',
      );
    }

    // Write packet ID (VarInt) after length VarInt
    final writtenIdSize = VarInt.write(buffer, packetLengthSize, id);
    
    // Verify written size matches expected
    if (writtenIdSize != packetIdSize) {
      throw Exception(
        'VarInt ID size mismatch: expected $packetIdSize bytes, wrote $writtenIdSize bytes for ID $id',
      );
    }

    // Write packet data after packet ID
    final dataStart = packetLengthSize + packetIdSize;
    final dataEnd = dataStart + data.length;
    
    // Verify we have enough space
    if (dataEnd > buffer.length) {
      throw Exception(
        'Packet data overflow: need $dataEnd bytes, buffer has ${buffer.length} bytes',
      );
    }
    
    // Copy data to buffer
    buffer.setRange(dataStart, dataEnd, data);

    // Final verification: total size must match
    if (buffer.length != totalSize) {
      throw Exception(
        'Packet size mismatch: expected $totalSize bytes, got ${buffer.length} bytes',
      );
    }

    return buffer;
  }
}
