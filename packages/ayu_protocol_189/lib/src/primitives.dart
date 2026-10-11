/// Internal primitive identifiers emitted by the 1.8.9 endpoint.
///
/// The `core.` prefix is reserved: these are not gameplay event contracts
/// and no plugin can subscribe to them. An event pack may list them as the
/// `sources` of a contract it provides.
abstract final class ProtocolPrimitive {
  /// A handshake packet was accepted. Not a player join.
  static const handshake = 'core.session.handshake';

  /// A login-start packet was accepted. Not a completed login.
  static const login = 'core.session.login';

  /// Login Success was sent and the connection is in the play state.
  static const playJoined = 'core.session.play_joined';

  /// A play-state connection closed.
  static const closed = 'core.session.closed';

  /// The server accepted a new position from a play-state client.
  /// High frequency. A newer value for the same entity replaces one that is
  /// still queued for a worker. Join and leave primitives are not coalesced.
  static const position = 'core.player.position';

  static const protocolVersion = 47;
  static const gameVersion = '1.8.9';
}
