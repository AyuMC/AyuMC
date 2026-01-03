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

    // Read packet length VarInt - CRITICAL: Use actual size consumed, not getSize()
    if (bytes.length < 1) {
      throw Exception(
        'Packet too short: need at least 1 byte for length, got ${bytes.length}',
      );
    }
    final lengthResult = VarInt.read(bytes, 0);
    final packetLength = lengthResult.value;
    final lengthSize = lengthResult.size;

    // Validate packet length is reasonable
    if (packetLength < 0 || packetLength > 2097152) {
      throw Exception(
        'Invalid packet length: $packetLength (must be 0-2097152)',
      );
    }

    // Read packet ID VarInt - CRITICAL: Use actual size consumed, not getSize()
    if (bytes.length < lengthSize + 1) {
      throw Exception(
        'Packet too short: need at least ${lengthSize + 1} bytes for packet ID, got ${bytes.length}',
      );
    }
    final idResult = VarInt.read(bytes, lengthSize);
    final packetId = idResult.value;
    final idSize = idResult.size;

    // CRITICAL: packetLength is the length of (packetId + data), not total bytes
    // So data starts after: lengthSize + idSize
    // And data ends at: lengthSize + packetLength
    final dataStart = lengthSize + idSize;
    final dataEnd = lengthSize + packetLength;

    if (dataEnd > bytes.length) {
      throw Exception(
        'Packet length mismatch: expected $dataEnd bytes, got ${bytes.length}',
      );
    }

    final data = bytes.sublist(dataStart, dataEnd);

    return Packet(id: packetId, data: data);
  }

  Uint8List toBytes() {
    // CRITICAL: Minecraft protocol packet format:
    // [Length VarInt][Packet ID VarInt][Data...]
    // Where Length = size of (Packet ID VarInt + Data)

    // Step 1: Calculate packet ID VarInt size
    final packetIdSize = VarInt.getSize(id);

    // Step 2: Calculate packet length (ID size + data length)
    // This is what goes in the Length VarInt field
    final packetLength = packetIdSize + data.length;

    // Step 3: Calculate how many bytes the Length VarInt will take
    final packetLengthSize = VarInt.getSize(packetLength);

    // Step 4: Calculate total buffer size
    // Total = Length VarInt size + Packet Length (which includes ID VarInt + data)
    final totalSize = packetLengthSize + packetLength;

    // Create buffer with exact size needed
    final buffer = Uint8List(totalSize);

    // Step 5: Write Length VarInt at the beginning
    final writtenLengthSize = VarInt.write(buffer, 0, packetLength);

    // CRITICAL VERIFICATION: Written size must match calculated size
    if (writtenLengthSize != packetLengthSize) {
      throw Exception(
        'CRITICAL: VarInt length size mismatch!\n'
        '  Expected: $packetLengthSize bytes\n'
        '  Wrote: $writtenLengthSize bytes\n'
        '  Value: $packetLength\n'
        '  This will cause client to read wrong packet length!',
      );
    }

    // Step 6: Write Packet ID VarInt after Length VarInt
    final writtenIdSize = VarInt.write(buffer, packetLengthSize, id);

    // CRITICAL VERIFICATION: Written size must match calculated size
    if (writtenIdSize != packetIdSize) {
      throw Exception(
        'CRITICAL: VarInt ID size mismatch!\n'
        '  Expected: $packetIdSize bytes\n'
        '  Wrote: $writtenIdSize bytes\n'
        '  ID: $id\n'
        '  This will cause client to read wrong packet ID!',
      );
    }

    // Step 7: Write packet data after Packet ID
    final dataStart = packetLengthSize + packetIdSize;
    final dataEnd = dataStart + data.length;

    // CRITICAL VERIFICATION: Ensure we have enough space
    if (dataEnd > buffer.length) {
      throw Exception(
        'CRITICAL: Packet data overflow!\n'
        '  Need: $dataEnd bytes\n'
        '  Have: ${buffer.length} bytes\n'
        '  Data length: ${data.length}\n'
        '  This will cause buffer overflow!',
      );
    }

    // Copy data to buffer
    buffer.setRange(dataStart, dataEnd, data);

    // Step 8: Final verification - total size must match
    if (buffer.length != totalSize) {
      throw Exception(
        'CRITICAL: Packet size mismatch!\n'
        '  Expected: $totalSize bytes\n'
        '  Got: ${buffer.length} bytes\n'
        '  This indicates a calculation error!',
      );
    }

    return buffer;
  }
}
