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

  void _join(SessionJoined event) => _write(
    enabled: config.snapshot.read(config.logJoins),
    message: config.joinMessage,
    name: event.player.name,
  );

  void _leave(SessionLeft event) => _write(
    enabled: config.snapshot.read(config.logLeaves),
    message: config.leaveMessage,
    name: event.player.name,
  );

  void _write({
    required bool enabled,
    required MessageOption message,
    required String name,
  }) {
    if (!enabled) return;
    context.log.info(
      '[SessionAudit] ${config.snapshot.render(message, PlaceholderContext(playerName: name))}',
    );
  }
}
