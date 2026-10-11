/// Public session contracts provided by the session Event Pack.
///
/// These types describe the wire payload. They are not the server's player
/// object and they do not live in the core.
library;

import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Identity copied from an event payload. It is not a live server player.
final class PlayerRef {
  const PlayerRef({required this.name, required this.uuid, required this.entityId});

  final String name;
  final String uuid;
  final int entityId;
}

final class SessionJoined {
  const SessionJoined({required this.player});

  final PlayerRef player;

  static SessionJoined decode(Map<String, Object?> data) =>
      SessionJoined(player: _player(data));
}

final class SessionLeft {
  const SessionLeft({required this.player});

  final PlayerRef player;

  static SessionLeft decode(Map<String, Object?> data) => SessionLeft(player: _player(data));
}

abstract final class SessionEvents {
  static final joined = EventContract<SessionJoined>(
    id: 'session.joined',
    version: '1.0.0',
    decode: SessionJoined.decode,
  );

  static final left = EventContract<SessionLeft>(
    id: 'session.left',
    version: '1.0.0',
    decode: SessionLeft.decode,
  );
}

PlayerRef _player(Map<String, Object?> data) => PlayerRef(
  name: data['name'] is String ? data['name'] as String : '',
  uuid: data['uuid'] is String ? data['uuid'] as String : '',
  entityId: data['entityId'] is int ? data['entityId'] as int : 0,
);
