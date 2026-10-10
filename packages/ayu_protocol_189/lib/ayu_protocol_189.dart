/// Minecraft Java Edition 1.8.9 network foundation: packet framing, the
/// handshake, status ping and the login-start packet.
///
/// This is not a playable server. After a login start the connection is
/// closed with a disconnect packet. What it does provide is a tested place
/// where the core reports internal primitives (`core.session.handshake`,
/// `core.session.login`) without defining any public gameplay event.
library;

export 'src/buffer.dart';
export 'src/endpoint.dart';
export 'src/primitives.dart';
