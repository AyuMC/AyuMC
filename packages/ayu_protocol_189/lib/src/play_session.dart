/// Authoritative view of one connection that has entered the play state.
/// Public gameplay events are not represented here.
final class PlaySession {
  PlaySession({
    required this.entityId,
    required this.name,
    required this.uuid,
    required this.x,
    required this.y,
    required this.z,
  });

  final int entityId;
  final String name;
  final String uuid;
  double x;
  double y;
  double z;
  double yaw = 0;
  double pitch = 0;
  bool onGround = true;

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
