import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Not installed with the server. An administrator adds the packaged `.ayu`
/// with `event install`.
void main() => runPlugin(_LoginEvents());

final class _LoginEvents extends AyuPlugin {
  @override
  Future<void> onEnable() async {
    await context.primitives.observe('core.session.login', (primitive) {
      final name = primitive.data['name'];
      final protocol = primitive.data['protocol'];
      context.events.publish('session.login_started', {
        'name': name is String ? name : '',
        'protocol': protocol is int ? protocol : 0,
      });
    });
    context.log.info('publishing session.login_started for ${context.plugin.version}');
  }
}
