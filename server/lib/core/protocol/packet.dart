import 'dart:typed_data';
import 'var_int.dart';

class Packet {
  final int id;
  final Uint8List data;

  Packet({required this.id, required this.data});

  factory Packet.fromBytes(Uint8List bytes) {
    final packetLength = VarInt.read(bytes, 0);
    final packetLengthSize = VarInt.getSize(packetLength);

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
    VarInt.write(buffer, 0, packetLength);

    // Write packet ID (VarInt)
    VarInt.write(buffer, packetLengthSize, id);

    // Write packet data
    buffer.setRange(packetLengthSize + packetIdSize, buffer.length, data);

    return buffer;
  }
}
