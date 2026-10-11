import 'dart:io';

import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Consumes the public session contracts. It does not watch the protocol.
void main() => runPlugin(_SessionAudit());

final class _SessionAudit extends AyuPlugin {
  EventSubscription? _joined;
  EventSubscription? _left;
  late final AuditConfig _settings;
  AyuConfigFile? _file;

  @override
  Future<void> onEnable() async {
    _settings = AuditConfig();
    final file = File(
      '${context.dataDirectory}${Platform.pathSeparator}config.ayuconf',
    );
    _file = AyuConfigFile(schema: _settings, file: file);
    await _report(await _file!.loadOrCreate());
    await _file!.watch(_report);
    _joined = await context.events.subscribe('session.joined', (event) {
      _logJoin(event.data['name']);
    });
    _left = await context.events.subscribe('session.left', (event) {
      _logLeave(event.data['name']);
    });
  }

  void _logJoin(Object? name) {
    final snapshot = _settings.snapshot;
    if (!snapshot.read(_settings.logJoins)) return;
    final text = snapshot.render(
      _settings.joinMessage,
      PlaceholderContext(playerName: '$name'),
    );
    context.log.info('[SessionAudit] $text');
  }

  void _logLeave(Object? name) {
    final snapshot = _settings.snapshot;
    if (!snapshot.read(_settings.logLeaves)) return;
    final text = snapshot.render(
      _settings.leaveMessage,
      PlaceholderContext(playerName: '$name'),
    );
    context.log.info('[SessionAudit] $text');
  }

  Future<void> _report(ConfigLoadResult result) async {
    final error = result.applied ? null : result.summary;
    if (result.applied) {
      context.log.info('[SessionAudit] config ${result.summary}');
    } else {
      context.log.error('[SessionAudit] config rejected: ${result.summary}');
    }
    context.reportConfigStatus(
      state: result.state,
      revision: result.revision,
      schemaVersion: _settings.schemaVersion,
      error: error,
    );
  }

  @override
  Future<void> onDisable() async {
    await _file?.close();
    await _joined?.cancel();
    await _left?.cancel();
    _joined = null;
    _left = null;
  }
}

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
