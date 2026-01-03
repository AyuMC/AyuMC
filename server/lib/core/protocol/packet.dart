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
    final packetLength = packetIdSize + data.length;

    // Calculate packet length VarInt size
    final packetLengthSize = VarInt.getSize(packetLength);

    // Total buffer size = length VarInt + packet length
    final buffer = Uint8List(packetLengthSize + packetLength);

    // Write packet length (VarInt)
    final writtenLengthSize = VarInt.write(buffer, 0, packetLength);
    if (writtenLengthSize != packetLengthSize) {
      throw Exception(
        'VarInt length size mismatch: expected $packetLengthSize, wrote $writtenLengthSize',
      );
    }

    // Write packet ID (VarInt)
    final writtenIdSize = VarInt.write(buffer, packetLengthSize, id);
    if (writtenIdSize != packetIdSize) {
      throw Exception(
        'VarInt ID size mismatch: expected $packetIdSize, wrote $writtenIdSize',
      );
    }

    // Write packet data
    final dataStart = packetLengthSize + packetIdSize;
    final dataEnd = dataStart + data.length;
    if (dataEnd > buffer.length) {
      throw Exception(
        'Packet data overflow: need $dataEnd bytes, buffer has ${buffer.length}',
      );
    }
    buffer.setRange(dataStart, dataEnd, data);

    // Verify total size matches expected
    final expectedTotalSize = packetLengthSize + packetLength;
    if (buffer.length != expectedTotalSize) {
      throw Exception(
        'Packet size mismatch: expected $expectedTotalSize bytes, got ${buffer.length}',
      );
    }

    return buffer;
  }
}
