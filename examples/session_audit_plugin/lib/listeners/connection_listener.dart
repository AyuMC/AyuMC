import 'package:ayu_plugin_api/ayu_plugin_api.dart';
import 'package:ayu_session_contracts/session.dart';

import '../config/audit_config.dart';

final class ConnectionListener extends Listener {
  ConnectionListener({required this.context, required this.config});

  final PluginContext context;
  final AuditConfig config;

  @override
  List<BoundHandler> get handlers => [
    on(SessionEvents.joined, _join),
    on(SessionEvents.left, _leave),
  ];

  void _join(SessionJoined event) =>
      _write(config.logJoins, config.joinMessage, event.player.name);

  void _leave(SessionLeft event) =>
      _write(config.logLeaves, config.leaveMessage, event.player.name);

  void _write(BoolOption enabled, MessageOption message, String name) {
    final snapshot = config.snapshot;
    final line = formatAuditLine(
      snapshot: snapshot,
      enabled: enabled,
      message: message,
      name: name,
    );
    if (line == null) return;
    context.log.info('[SessionAudit] $line');
  }
}

/// One snapshot supplies both the switch and the template.
String? formatAuditLine({
  required ConfigSnapshot snapshot,
  required BoolOption enabled,
  required MessageOption message,
  required String name,
}) {
  if (!snapshot.read(enabled)) return null;
  return snapshot.render(message, PlaceholderContext(playerName: name));
}
