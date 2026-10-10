// Plugin fixture: counts session.login_started events from an event pack.
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(_LoginPlugin());

final class _LoginPlugin extends AyuPlugin {
  int _logins = 0;

  @override
  Future<void> onEnable() async {
    await context.events.subscribe('session.login_started', (event) {
      _logins++;
      context.log.info('login ${event.data['name']}');
    });
    await context.commands.register('logins', (_) => CommandResult.ok('$_logins'));
  }
}
