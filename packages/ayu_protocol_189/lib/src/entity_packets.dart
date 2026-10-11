import 'dart:typed_data';

import 'buffer.dart';
import 'play_session.dart';

/// Quantized pose matching what a 1.8.9 client stores after a spawn, relative
/// move, look, or teleport. Later viewers are spawned from this snapshot so
/// their relative deltas start where everyone else already is.
final class QuantizedPose {
  const QuantizedPose({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
    required this.pitch,
    required this.onGround,
    required this.flags,
  });

  factory QuantizedPose.of(PlaySession session) {
    return QuantizedPose(
      x: fixedPoint(session.x),
      y: fixedPoint(session.y),
      z: fixedPoint(session.z),
      yaw: angleByte(session.yaw),
      pitch: angleByte(session.pitch),
      onGround: session.onGround,
      flags: session.metadataFlags,
    );
  }

  /// `floor(coordinate * 32)`, the protocol 47 fixed-point position.
  final int x;
  final int y;
  final int z;

  /// Low 8 bits of the protocol 47 angle.
  final int yaw;
  final int pitch;
  final bool onGround;

  /// Entity metadata index 0. Bit 1 is sneak, bit 3 is sprint.
  final int flags;

  bool sameAs(QuantizedPose other) =>
      x == other.x &&
      y == other.y &&
      z == other.z &&
      yaw == other.yaw &&
      pitch == other.pitch &&
      onGround == other.onGround &&
      flags == other.flags;
}

/// Protocol 47 fixed point. Matches `MathHelper.floor_double(value * 32)`.
int fixedPoint(double coordinate) {
  final scaled = coordinate * 32.0;
  if (!scaled.isFinite) return 0;
  return scaled.floor();
}

/// Protocol 47 angle byte. Java casts `degrees * 256 / 360` toward zero.
int angleByte(double degrees) {
  final scaled = degrees * 256.0 / 360.0;
  if (!scaled.isFinite) return 0;
  return scaled.truncate() & 0xFF;
}

/// A relative delta fits in a protocol 47 move byte when it is in `-128..127`.
bool relativeDeltaFits(int delta) => delta >= -128 && delta < 128;

/// Clientbound play packet ids below are protocol 47. They are not the ids
/// used by 1.9 or later.

Uint8List playerListAdd(PlaySession player) {
  return encodePacket(0x38, [
    ...encodeVarInt(0),
    ...encodeVarInt(1),
    ...player.uuidBytes,
    ...encodeString(player.name),
    ...encodeVarInt(0),
    ...encodeVarInt(0),
    ...encodeVarInt(0),
    0,
  ]);
}

Uint8List playerListRemove(PlaySession player) {
  return encodePacket(0x38, [
    ...encodeVarInt(4),
    ...encodeVarInt(1),
    ...player.uuidBytes,
  ]);
}

Uint8List spawnPlayer(PlaySession player, QuantizedPose pose) {
  return encodePacket(0x0C, [
    ...encodeVarInt(player.entityId),
    ...player.uuidBytes,
    ...encodeInt(pose.x),
    ...encodeInt(pose.y),
    ...encodeInt(pose.z),
    pose.yaw,
    pose.pitch,
    0,
    0,
    ..._metadata(pose.flags),
  ]);
}

Uint8List entityRelativeMovePacket(
  int entityId,
  QuantizedPose pose,
  int dx,
  int dy,
  int dz,
) {
  return encodePacket(0x15, [
    ...encodeVarInt(entityId),
    dx & 0xFF,
    dy & 0xFF,
    dz & 0xFF,
    pose.onGround ? 1 : 0,
  ]);
}

Uint8List entityLookPacket(int entityId, QuantizedPose pose) {
  return encodePacket(0x16, [
    ...encodeVarInt(entityId),
    pose.yaw,
    pose.pitch,
    pose.onGround ? 1 : 0,
  ]);
}

Uint8List entityLookMovePacket(
  int entityId,
  QuantizedPose pose,
  int dx,
  int dy,
  int dz,
) {
  return encodePacket(0x17, [
    ...encodeVarInt(entityId),
    dx & 0xFF,
    dy & 0xFF,
    dz & 0xFF,
    pose.yaw,
    pose.pitch,
    pose.onGround ? 1 : 0,
  ]);
}

Uint8List entityTeleportPacket(int entityId, QuantizedPose pose) {
  return encodePacket(0x18, [
    ...encodeVarInt(entityId),
    ...encodeInt(pose.x),
    ...encodeInt(pose.y),
    ...encodeInt(pose.z),
    pose.yaw,
    pose.pitch,
    pose.onGround ? 1 : 0,
  ]);
}

Uint8List entityHeadLookPacket(int entityId, int yaw) {
  return encodePacket(0x19, [...encodeVarInt(entityId), yaw & 0xFF]);
}

Uint8List destroyEntitiesPacket(int entityId) {
  return encodePacket(0x13, [...encodeVarInt(1), ...encodeVarInt(entityId)]);
}

Uint8List entityMetadataPacket({required int entityId, required int flags}) {
  return encodePacket(0x1C, [...encodeVarInt(entityId), ..._metadata(flags)]);
}

/// Index 0, type byte, then the 0x7F terminator. Protocol 47 packs the index
/// and type into one header: `(type << 5) | index`.
List<int> _metadata(int flags) => [0x00, flags & 0xFF, 0x7F];
