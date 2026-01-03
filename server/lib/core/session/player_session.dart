import '../connection/connection_state.dart';

/// Represents a player's session data.
///
/// Uses minimal memory footprint and efficient data structures.
class PlayerSession {
  final String uuid;
  final String username;
  final DateTime loginTime;

  ConnectionState _state;
  bool _isActive;

  /// Protocol version from handshake (e.g., 765 for 1.20.4)
  int protocolVersion;

  // Player position (ultra-compact storage)
  double x = 0.0;
  double y = 64.0; // Default spawn height
  double z = 0.0;
  double yaw = 0.0;
  double pitch = 0.0;
  bool onGround = true;

  /// Teleport confirmation state
  bool _teleportConfirmed = false;
  int _pendingTeleportId = 0;

  bool get teleportConfirmed => _teleportConfirmed;
  int get pendingTeleportId => _pendingTeleportId;

  void setPendingTeleport(int teleportId) {
    _pendingTeleportId = teleportId;
    _teleportConfirmed = false;
  }

  void confirmTeleport(int teleportId) {
    if (teleportId == _pendingTeleportId) {
      _teleportConfirmed = true;
    }
  }

  PlayerSession({
    required this.uuid,
    required this.username,
    ConnectionState initialState = ConnectionState.login,
    this.protocolVersion = 765, // Default: 1.20.4
  }) : loginTime = DateTime.now(),
       _state = initialState,
       _isActive = true;

  /// Returns the current connection state.
  ConnectionState get state => _state;

  /// Returns whether the session is active.
  bool get isActive => _isActive;

  /// Transitions to a new connection state.
  void transitionTo(ConnectionState newState) {
    if (!_isActive) {
      return;
    }
    _state = newState;
  }

  /// Marks the session as inactive (disconnected).
  void deactivate() {
    _isActive = false;
    _state = ConnectionState.closing;
  }

  /// Returns the session duration.
  Duration get duration => DateTime.now().difference(loginTime);

  @override
  String toString() =>
      'PlayerSession(uuid: $uuid, name: $username, state: $_state)';
}
