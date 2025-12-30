import 'dart:typed_data';
import '../../packet_reader.dart';
import '../../packet_writer.dart';
import '../../protocol_registry.dart';
import '../../var_int.dart';

/// Keep Alive packet for maintaining connection (Clientbound).
///
/// Ultra-optimized implementation with pre-allocated buffer.
class KeepAliveClientboundPacket {
  final int keepAliveId;
  final int protocolVersion;

  const KeepAliveClientboundPacket(
    this.keepAliveId, {
    this.protocolVersion = 765, // Default: 1.20.4
  });

  /// Builds the packet bytes with minimal allocations.
  Uint8List toBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final writer = PacketWriter();
    writer.writeVarInt(packetIds.playKeepAliveClientbound);
    writer.writeLong(keepAliveId);
    return writer.toBytes();
  }

  /// Creates a framed packet ready for transmission.
  Uint8List toFramedBytes() {
    final payload = toBytes();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }
}

/// Keep Alive packet from client (Serverbound).
///
/// Parses the client's response to verify connection is alive.
class KeepAliveServerboundPacket {
  final int keepAliveId;

  const KeepAliveServerboundPacket(this.keepAliveId);

  /// Parses a Keep Alive packet from raw bytes (payload only).
  factory KeepAliveServerboundPacket.parse(Uint8List data) {
    final reader = PacketReader(data);
    final keepAliveId = reader.readLong();
    return KeepAliveServerboundPacket(keepAliveId);
  }
}
