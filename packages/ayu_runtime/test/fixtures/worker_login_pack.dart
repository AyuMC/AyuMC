// Event pack fixture: turns the internal login primitive into a public contract.
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(_LoginPack());

final class _LoginPack extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.primitives.observe('core.session.login', (primitive) {
      final name = primitive.data['name'];
      context.events.publish('session.login_started', {'name': name is String ? name : ''});
    });
    context.log.info('login pack observing core.session.login');
  }
}
