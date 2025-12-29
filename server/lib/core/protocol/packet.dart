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
    final data = bytes.sublist(dataStart, packetLength + packetLengthSize);

    return Packet(id: packetId, data: data);
  }

  Uint8List toBytes() {
    final packetIdSize = VarInt.getSize(id);
    final packetLength = packetIdSize + data.length;
    final packetLengthSize = VarInt.getSize(packetLength);

    final buffer = Uint8List(packetLengthSize + packetLength);
    VarInt.write(buffer, 0, packetLength);
    VarInt.write(buffer, packetLengthSize, id);
    buffer.setRange(packetLengthSize + packetIdSize, buffer.length, data);

    return buffer;
  }
}
