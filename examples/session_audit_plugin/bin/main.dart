import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Consumes the public session contracts. It does not watch the protocol.
void main() => runPlugin(_SessionAudit());

final class _SessionAudit extends AyuPlugin {
  EventSubscription? _joined;
  EventSubscription? _left;

  @override
  Future<void> onEnable() async {
    _joined = await context.events.subscribe('session.joined', (event) {
      context.log.info('[SessionAudit] PLAYER_JOINED username=${event.data['name']}');
    });
    _left = await context.events.subscribe('session.left', (event) {
      context.log.info('[SessionAudit] PLAYER_LEFT username=${event.data['name']}');
    });
  }

  @override
  Future<void> onDisable() async {
    await _joined?.cancel();
    await _left?.cancel();
    _joined = null;
    _left = null;
  }
}
