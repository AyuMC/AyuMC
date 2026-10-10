// Test worker: a well-behaved plugin built on the real SDK.
//
// Commands: echo <args>, events, crash (exits with code 3 shortly after
// answering), spin (blocks the event loop forever so shutdown is ignored).
import 'dart:io';

import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(_FixturePlugin());

final class _FixturePlugin extends AyuPlugin {
  int _events = 0;

  @override
  Future<void> onEnable() async {
    await context.commands.register('echo', (call) => CommandResult.ok(call.args.join(' ')), aliases: ['say']);
    await context.commands.register('events', (call) => CommandResult.ok('$_events'));
    await context.commands.register('crash', (call) {
      context.timers.once(const Duration(milliseconds: 50), () => exit(3));
      return const CommandResult.ok('crashing');
    });
    await context.commands.register('spin', (call) {
      while (true) {}
    });
    await context.commands.register('config', (call) => CommandResult.ok('${context.config['greeting']}'));
    await context.events.subscribe('test.event', (event) => _events++);
    context.log.info('fixture enabled in ${context.dataDirectory}');
  }

  @override
  Future<void> onDisable() async {
    context.log.info('fixture disabled');
  }
}
