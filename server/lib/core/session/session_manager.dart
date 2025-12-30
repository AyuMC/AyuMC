import 'dart:collection';

import 'player_session.dart';

/// Manages all active player sessions with optimized data structures.
///
/// Uses lock-free operations where possible and efficient lookups.
class SessionManager {
  static final SessionManager _instance = SessionManager._internal();

  factory SessionManager() => _instance;

  SessionManager._internal();

  final Map<String, PlayerSession> _sessionsByUuid = {};
  final Map<String, PlayerSession> _sessionsByUsername = {};

  static const int kMaxSessions = 5000;

  /// Adds a new player session.
  ///
  /// Returns false if the session limit is reached.
  bool addSession(PlayerSession session) {
    if (_sessionsByUuid.length >= kMaxSessions) {
      return false;
    }

    _sessionsByUuid[session.uuid] = session;
    _sessionsByUsername[session.username.toLowerCase()] = session;

    print(
      '[SessionManager] Player joined: ${session.username} (${_sessionsByUuid.length} online)',
    );
    return true;
  }

  /// Removes a player session.
  void removeSession(String uuid) {
    final session = _sessionsByUuid.remove(uuid);
    if (session != null) {
      _sessionsByUsername.remove(session.username.toLowerCase());
      session.deactivate();
      print(
        '[SessionManager] Player left: ${session.username} (${_sessionsByUuid.length} online)',
      );
    }
  }

  /// Gets a session by UUID.
  PlayerSession? getByUuid(String uuid) {
    return _sessionsByUuid[uuid];
  }

  /// Gets a session by username (case-insensitive).
  PlayerSession? getByUsername(String username) {
    return _sessionsByUsername[username.toLowerCase()];
  }

  /// Checks if a username is already online.
  bool isUsernameOnline(String username) {
    return _sessionsByUsername.containsKey(username.toLowerCase());
  }

  /// Returns the number of active sessions.
  int get sessionCount => _sessionsByUuid.length;

  /// Returns all active sessions.
  Iterable<PlayerSession> get activeSessions =>
      UnmodifiableListView(_sessionsByUuid.values);

  /// Clears all sessions (for shutdown).
  void clear() {
    for (final session in _sessionsByUuid.values) {
      session.deactivate();
    }
    _sessionsByUuid.clear();
    _sessionsByUsername.clear();
  }
}
