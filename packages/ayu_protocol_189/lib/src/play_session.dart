import 'dart:typed_data';

/// Authoritative view of one connection that has entered the play state.
/// Public gameplay events are not represented here.
final class PlaySession {
  PlaySession({
    required this.entityId,
    required this.name,
    required this.uuid,
    required this.uuidBytes,
    required this.x,
    required this.y,
    required this.z,
  });

  final int entityId;
  final String name;

  /// Hyphenated UUID sent in Login Success.
  final String uuid;

  /// The same UUID as 16 protocol-47 bytes, used by the player list and spawn.
  final Uint8List uuidBytes;
  double x;
  double y;
  double z;
  double yaw = 0;
  double pitch = 0;
  bool onGround = true;

  /// Set from the client entity-action packet. Replication copies these into
  /// entity metadata. They do not change movement physics.
  bool sneaking = false;
  bool sprinting = false;

  /// Chunks reported by the 1.8.9 client settings packet. Null until that
  /// packet arrives; the server view distance is used in the meantime.
  int? clientViewChunks;

  /// Protocol 47 entity flags: bit 1 sneak, bit 3 sprint.
  int get metadataFlags => (sneaking ? 0x02 : 0) | (sprinting ? 0x08 : 0);

  static const spawnX = 8.5;
  static const spawnY = 16.0;
  static const spawnZ = 8.5;

  Map<String, Object?> toFields() => {
    'entityId': entityId,
    'name': name,
    'uuid': uuid,
    'x': x,
    'y': y,
    'z': z,
    'yaw': yaw,
    'pitch': pitch,
    'onGround': onGround,
  };
}
