import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_events/event_bus.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayu_profile/ayu_profile.dart';
import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_runtime/ayu_runtime.dart';

import 'ayu_lifecycle.dart';
import 'ayu_states.dart';
import 'events/server_started_event.dart';
import 'plugin_console_command.dart';

/// The server: lifecycle, console commands and the package host.
///
/// Public gameplay events are not emitted here. Event packs observe internal
/// primitives through [PluginHost.primitives] and publish contracts of their
/// own.
class AyuServer {
  AyuServer({
    Directory? rootDirectory,
    this.profileId,
    this.pluginOptions = const PluginRuntimeOptions(),
    this.pluginRuntimeExecutable,
  }) : rootDirectory = rootDirectory ?? Directory('.');

  final Directory rootDirectory;

  /// Overrides the profile stored in `config/server.json`.
  final String? profileId;
  final PluginRuntimeOptions pluginOptions;
  final String? pluginRuntimeExecutable;

  final EventBus events = EventBus();
  final Logger logger = Logger('AyuMC');
  final ServerLifecycle lifecycle = ServerLifecycle();
  final CommandManager commands = CommandManager();

  late final PluginHost plugins;
  late final ServerProfile profile;
  late final ServerLayout layout;
  ProtocolEndpoint? network;

  StreamSubscription<RegistryChange>? _registrySubscription;
  final Map<String, Map<String, List<String>>> _mirrored = {};

  Future<void> start() async {
    lifecycle.setState(ServerState.starting);
    layout = ServerLayout(rootDirectory);
    await layout.create();
    profile = await _resolveProfile();
    logger.info('Profile ${profile.id} (Minecraft ${profile.gameVersion}, protocol ${profile.protocolVersion}).');
    plugins = PluginHost(
      rootDirectory: rootDirectory,
      profileId: profile.id,
      options: pluginOptions,
      runtimeExecutable: pluginRuntimeExecutable,
      logger: Logger('Plugins'),
    );
    logger.info('Server starting...');
    _registerBuiltinCommands();
    _registrySubscription = plugins.registry.changes.listen(_mirrorPluginCommand);
    await plugins.start();
    await _listen();
    logger.info('Server started. No gameplay event packs are installed by default.');
    events.emit(ServerStartedEvent());
    lifecycle.setState(ServerState.running);
  }

  Future<void> stop() async {
    lifecycle.setState(ServerState.stopping);
    logger.info('Server stopping...');
    await network?.close();
    network = null;
    await plugins.dispose();
    await _registrySubscription?.cancel();
    logger.warn('Server stopped.');
    lifecycle.setState(ServerState.stopped);
  }

  Future<void> _listen() async {
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC ${profile.gameVersion}',
      protocolVersion: profile.protocolVersion,
      description: 'AyuMC ${profile.id}',
      interestedIn: (id) => plugins.primitives.hasObservers(id) || plugins.primitives.hasDeciders(id),
      onPrimitive: (id, data) {
        if (plugins.primitives.hasDeciders(id)) {
          unawaited(plugins.primitives.decide(id, data));
        } else if (plugins.primitives.hasObservers(id)) {
          plugins.primitives.observe(id, data);
        }
      },
    );
    try {
      await endpoint.bind(port: _configuredPort());
      network = endpoint;
      logger.info('Listening for Minecraft ${profile.gameVersion} on ${endpoint.port}.');
    } on SocketException catch (e) {
      logger.error('Minecraft listener was not started: ${e.message}. Plugins keep running.');
    }
  }

  int _configuredPort() {
    final file = layout.serverConfigFile;
    if (!file.existsSync()) return 25565;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['port'] is int) return decoded['port'] as int;
    } on FormatException {
      logger.warn('${file.path} is not valid JSON; using port 25565');
    }
    return 25565;
  }

  Future<ServerProfile> _resolveProfile() async {
    if (profileId != null) {
      final selected = ProfileCatalog.byId(profileId!);
      if (selected == null) {
        throw ProfileException('unknown profile "$profileId"; available: ${ProfileCatalog.all.map((p) => p.id).join(', ')}');
      }
      return selected;
    }
    return ProfileSelection(layout.serverConfigFile).load();
  }

  void _registerBuiltinCommands() {
    commands.register(Command(name: 'ping', description: 'Test command', execute: (_) => logger.info('pong!')));
    commands.register(Command(name: 'say', description: 'Broadcast message', execute: (args) => logger.info(args.join(' '))));
    commands.register(PackageConsoleCommand(plugins, logger, eventPacks: false).command);
    commands.register(PackageConsoleCommand(plugins, logger, eventPacks: true).command);
    commands.register(Command(name: 'profile', description: 'Show or select the server profile.', execute: _profile));
    commands.register(Command(name: 'contracts', description: 'List event contracts and their providers.', execute: (_) => _contracts()));
  }

  Future<void> _profile(List<String> args) async {
    if (args.isEmpty || args.first == 'list') {
      for (final candidate in ProfileCatalog.all) {
        final mark = candidate.id == profile.id ? '*' : ' ';
        logger.info('$mark ${candidate.id}  Minecraft ${candidate.gameVersion}  protocol ${candidate.protocolVersion}');
      }
      logger.info('active: ${profile.id} (selection in ${layout.serverConfigFile.path} applies on the next start)');
      return;
    }
    if (args.first == 'select' && args.length >= 2) {
      final selected = ProfileCatalog.byId(args[1]);
      if (selected == null) {
        logger.error('unknown profile "${args[1]}"');
        return;
      }
      await ProfileSelection(layout.serverConfigFile).save(selected);
      logger.info('saved ${selected.id}; restart the server to run it');
      return;
    }
    logger.info('profile list | profile select <id>');
  }

  void _contracts() {
    final rows = plugins.contracts.describe();
    if (rows.isEmpty) {
      logger.info('no event contracts declared');
      return;
    }
    for (final row in rows) {
      final provider = row.providerId == null ? 'no provider' : '${row.providerId} ${row.version} (${row.mode!.name})';
      logger.info('${row.id}: $provider; subscribers ${row.subscribers.join(', ')}; required by ${row.requiredBy.join(', ')}');
    }
  }

  void _mirrorPluginCommand(RegistryChange change) {
    switch (change) {
      case CommandRegistered(:final command):
        final exposed = <String>[];
        for (final name in [command.spec.name, ...command.spec.aliases]) {
          if (commands.has(name)) {
            logger.warn('package "${change.pluginId}" command "$name" shadows a built-in and is not exposed on the console');
            continue;
          }
          commands.register(Command(
            name: name,
            description: command.spec.description ?? 'Provided by ${change.pluginId}',
            execute: (args) => _runPluginCommand(name, args),
          ));
          exposed.add(name);
        }
        _mirrored.putIfAbsent(change.pluginId, () => {})[command.spec.name] = exposed;
      case CommandUnregistered(:final name):
        for (final consoleName in _mirrored[change.pluginId]?.remove(name) ?? const <String>[]) {
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
