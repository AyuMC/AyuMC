import 'package:ayu_plugin_api/ayu_plugin_api.dart';

/// Reference plugin. Everything it touches on the server goes through
/// [PluginContext]; it never sees server objects directly.
final class ExamplePlugin extends AyuPlugin {
  int _joins = 0;
  int _ticks = 0;

  String get _greeting => context.config['greeting'] as String? ?? 'Hello';

  /// Operators can namespace the commands (e.g. `ex_hello`) when another
  /// plugin already owns the plain names.
  String get _prefix => context.config['commandPrefix'] as String? ?? '';

  @override
  Future<void> onEnable() async {
    await context.commands.register(
      '${_prefix}hello',
      _hello,
      description: 'Greets the sender or the given name',
      usage: '/${_prefix}hello [name]',
      aliases: ['${_prefix}hi'],
    );
    await context.commands.register(
      '${_prefix}stats',
      (_) => CommandResult.ok('joins=$_joins ticks=$_ticks'),
      description: 'Shows counters kept by the example plugin',
    );
    await context.events.subscribe('player.join', (event) {
      _joins++;
      context.log.info('player joined: ${event.data['player'] ?? 'unknown'}');
    });
    await context.events.subscribe('server.started', (_) {
      context.log.info('server is up; ${context.plugin.name} ${context.plugin.version} ready');
    });
    context.timers.periodic(const Duration(seconds: 30), (_) => _ticks++);
    context.log.info('enabled with greeting "$_greeting"; data in ${context.dataDirectory}');
  }

  @override
  void onDisable() {
    context.log.info('disabled after $_joins joins and $_ticks ticks');
  }

  CommandResult _hello(CommandInvocation call) {
    final who = call.args.isEmpty ? call.sender : call.args.join(' ');
    return CommandResult.ok('$_greeting, $who!');
  }
}
