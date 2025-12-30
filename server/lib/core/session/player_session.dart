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

  PlayerSession({
    required this.uuid,
    required this.username,
    ConnectionState initialState = ConnectionState.login,
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
