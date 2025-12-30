import 'dart:typed_data';

import '../../packet_reader.dart';
import '../../packet_writer.dart';
import '../../var_int.dart';

/// Synchronize Player Position packet (Clientbound).
///
/// Sent by server to set/update player position.
/// Ultra-optimized with pre-computed bytes.
class SyncPlayerPositionPacket {
  final double x;
  final double y;
  final double z;
  final double yaw;
  final double pitch;
  final int flags;
  final int teleportId;
  final int protocolVersion;

  const SyncPlayerPositionPacket({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
    required this.pitch,
    this.flags = 0,
    this.teleportId = 0,
    this.protocolVersion = 765,
  });

  /// Builds the packet payload (without packet ID).
  ///
  /// The Packet wrapper will add packet ID and length.
  Uint8List toBytes() {
    final writer = PacketWriter();
    writer.writeDouble(x);
    writer.writeDouble(y);
    writer.writeDouble(z);
    writer.writeFloat(yaw);
    writer.writeFloat(pitch);
    writer.writeByte(flags);
    writer.writeVarInt(teleportId);
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

/// Set Default Spawn Position packet (Clientbound).
///
/// Sets the player's spawn point location.
class SetDefaultSpawnPositionPacket {
  final int x;
  final int y;
  final int z;
  final double angle;
  final int protocolVersion;

  const SetDefaultSpawnPositionPacket({
    required this.x,
    required this.y,
    required this.z,
    this.angle = 0.0,
    this.protocolVersion = 765,
  });

  /// Builds the packet payload (without packet ID).
  ///
  /// The Packet wrapper will add packet ID and length.
  Uint8List toBytes() {
    final writer = PacketWriter();
    writer.writePosition(x, y, z);
    writer.writeFloat(angle);
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

/// Player Position packet (Serverbound).
///
/// Received from client when player moves.
class PlayerPositionServerboundPacket {
  final double x;
  final double y;
  final double z;
  final bool onGround;

  const PlayerPositionServerboundPacket({
    required this.x,
    required this.y,
    required this.z,
    required this.onGround,
  });

  /// Parses position packet from raw bytes.
  factory PlayerPositionServerboundPacket.parse(Uint8List data) {
    final reader = PacketReader(data);
    final x = reader.readDouble();
    final y = reader.readDouble();
    final z = reader.readDouble();
    final onGround = reader.readBool();
    return PlayerPositionServerboundPacket(
      x: x,
      y: y,
      z: z,
      onGround: onGround,
    );
  }
}

/// Player Position and Rotation packet (Serverbound).
class PlayerPositionRotationServerboundPacket {
  final double x;
  final double y;
  final double z;
  final double yaw;
  final double pitch;
  final bool onGround;

  const PlayerPositionRotationServerboundPacket({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
    required this.pitch,
    required this.onGround,
  });

  factory PlayerPositionRotationServerboundPacket.parse(Uint8List data) {
    final reader = PacketReader(data);
    final x = reader.readDouble();
    final y = reader.readDouble();
    final z = reader.readDouble();
    final yaw = reader.readFloat();
    final pitch = reader.readFloat();
    final onGround = reader.readBool();
    return PlayerPositionRotationServerboundPacket(
      x: x,
      y: y,
      z: z,
      yaw: yaw,
      pitch: pitch,
      onGround: onGround,
    );
  }
}
