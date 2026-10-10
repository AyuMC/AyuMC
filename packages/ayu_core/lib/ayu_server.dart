import 'dart:async';
import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_events/event_bus.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayu_runtime/ayu_runtime.dart';

import 'ayu_lifecycle.dart';
import 'ayu_states.dart';
import 'events/server_started_event.dart';
import 'plugin_console_command.dart';

/// The server: lifecycle, console commands, in-process events and the
/// plugin host. Plugins never run in this process; see `ayu_runtime`.
class AyuServer {
  AyuServer({
    Directory? pluginDirectory,
    PluginRuntimeOptions pluginOptions = const PluginRuntimeOptions(),
    String? pluginRuntimeExecutable,
  }) : plugins = PluginHost(
          rootDirectory: pluginDirectory ?? Directory('plugins'),
          options: pluginOptions,
          runtimeExecutable: pluginRuntimeExecutable,
          logger: Logger('Plugins'),
        );

  final EventBus events = EventBus();
  final Logger logger = Logger('AyuMC');
  final PluginHost plugins;
  final ServerLifecycle lifecycle = ServerLifecycle();
  final CommandManager commands = CommandManager();

  StreamSubscription<RegistryChange>? _registrySubscription;

  /// Console names mirrored per plugin, keyed by the plugin command name,
  /// so aliases are removed together with their command.
  final Map<String, Map<String, List<String>>> _mirrored = {};

  Future<void> start() async {
    lifecycle.setState(ServerState.starting);
    logger.info('Server starting...');
    _registerBuiltinCommands();
    _registrySubscription = plugins.registry.changes.listen(_mirrorPluginCommand);
    await plugins.start();
    logger.info('Server Started.');
    events.emit(ServerStartedEvent());
    plugins.emitEvent('server.started', const {});
    lifecycle.setState(ServerState.running);
  }

  Future<void> stop() async {
    lifecycle.setState(ServerState.stopping);
    logger.info('Server stopping...');
    plugins.emitEvent('server.stopping', const {});
    await plugins.dispose();
    await _registrySubscription?.cancel();
    logger.warn('Server stopped.');
    lifecycle.setState(ServerState.stopped);
  }

  void _registerBuiltinCommands() {
    commands.register(Command(
      name: 'ping',
      description: 'Test command',
      execute: (_) => logger.info('pong!'),
    ));
    commands.register(Command(
      name: 'say',
      description: 'Broadcast message',
      execute: (args) => logger.info(args.join(' ')),
    ));
    commands.register(PluginConsoleCommand(plugins, logger).command);
  }

  /// Keeps the console in sync with commands plugins register: each one
  /// becomes a console command that forwards to the owning worker.
  void _mirrorPluginCommand(RegistryChange change) {
    switch (change) {
      case CommandRegistered(:final command):
        final exposed = <String>[];
        for (final name in [command.spec.name, ...command.spec.aliases]) {
          if (commands.has(name)) {
            logger.warn('plugin "${change.pluginId}" command "$name" shadows a built-in and is not exposed on the console');
            continue;
          }
          commands.register(Command(
            name: name,
            description: command.spec.description ?? 'Provided by plugin ${change.pluginId}',
            execute: (args) => _runPluginCommand(name, args),
          ));
          exposed.add(name);
        }
        _mirrored.putIfAbsent(change.pluginId, () => {})[command.spec.name] = exposed;
      case CommandUnregistered(:final name):
        final exposed = _mirrored[change.pluginId]?.remove(name) ?? const [];
        for (final consoleName in exposed) {
          commands.unregister(consoleName);
        }
    }
  }

  Future<void> _runPluginCommand(String name, List<String> args) async {
    try {
      final result = await plugins.executeCommand(name, args, sender: 'console');
      final message = result.message ?? (result.success ? 'ok' : 'failed');
      if (result.success) {
        logger.info(message);
      } else {
        logger.warn(message);
      }
    } on PluginHostException catch (e) {
      logger.error(e.message);
    }
  }
}
