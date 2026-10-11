import 'package:ayu_plugin_api/ayu_plugin_api.dart';

final class AuditConfig extends AyuConfig {
  late final MessageOption joinMessage;
  late final MessageOption leaveMessage;
  late final BoolOption logJoins;
  late final BoolOption logLeaves;

  @override
  void define() {
    joinMessage = add(
      MessageOption(
        'messages.join',
        defaultValue: 'PLAYER_JOINED username={session_audit.player.name}',
        placeholders: {AuditPlaceholders.playerName},
        description: 'Logged when a play session starts.',
      ),
    );
    leaveMessage = add(
      MessageOption(
        'messages.leave',
        defaultValue: 'PLAYER_LEFT username={session_audit.player.name}',
        placeholders: {AuditPlaceholders.playerName},
        description: 'Logged when a play session ends.',
      ),
    );
    logJoins = add(
      BoolOption(
        'logging.log-joins',
        defaultValue: true,
        description: 'Write the join line.',
      ),
    );
    logLeaves = add(
      BoolOption(
        'logging.log-leaves',
        defaultValue: true,
        description: 'Write the leave line.',
      ),
    );
  }
}

abstract final class AuditPlaceholders {
  static final playerName = Placeholder<String>(
    id: 'session_audit.player.name',
    description: 'Username of the player in this session message.',
    resolve: (context) => context.requirePlayerName(),
  );
}
