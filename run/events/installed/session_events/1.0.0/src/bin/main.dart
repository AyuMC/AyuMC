import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Observes internal play-state transitions and publishes the public
/// session contracts. The core does not define those contracts.
void main() => runPlugin(_SessionEvents());

final class _SessionEvents extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.primitives.observe('core.session.play_joined', (primitive) {
      context.events.publish('session.joined', _identity(primitive));
    });
    await context.primitives.observe('core.session.closed', (primitive) {
      context.events.publish('session.left', _identity(primitive));
    });
  }

  Map<String, Object?> _identity(PrimitiveEnvelope primitive) => {
    'entityId': primitive.data['entityId'] ?? 0,
    'name': primitive.data['name'] ?? '',
    'uuid': primitive.data['uuid'] ?? '',
  };
}
