/// Represents the current state of a client connection.
///
/// States follow the Minecraft protocol flow:
/// Handshake → Status/Login → Play
enum ConnectionState {
  /// Initial handshake state
  handshake,

  /// Status request (server list ping)
  status,

  /// Login process
  login,

  /// Active gameplay
  play,

  /// Connection being closed
  closing,
}

/// Extension methods for connection state management.
extension ConnectionStateExtensions on ConnectionState {
  /// Returns whether this state allows status packets.
  bool get allowsStatus => this == ConnectionState.status;

  /// Returns whether this state allows login packets.
  bool get allowsLogin => this == ConnectionState.login;

  /// Returns whether this state allows play packets.
  bool get allowsPlay => this == ConnectionState.play;

  /// Returns whether the connection is active.
  bool get isActive => this != ConnectionState.closing;
}
