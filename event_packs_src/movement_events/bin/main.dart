import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Republishes accepted positions. The core only tracks the coordinates.
void main() => runPlugin(_MovementEvents());

final class _MovementEvents extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.primitives.observe('core.player.position', (primitive) {
      context.events.publish('player.position_changed', primitive.data);
    });
  }
}
