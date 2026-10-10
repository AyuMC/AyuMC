/// Internal primitive identifiers emitted by the 1.8.9 endpoint.
///
/// The `core.` prefix is reserved: these are not gameplay event contracts
/// and no plugin can subscribe to them. An event pack may list them as the
/// `sources` of a contract it provides.
abstract final class ProtocolPrimitive {
  static const handshake = 'core.session.handshake';
  static const login = 'core.session.login';

  static const protocolVersion = 47;
  static const gameVersion = '1.8.9';
}
