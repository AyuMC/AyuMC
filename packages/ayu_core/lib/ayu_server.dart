import 'dart:async';
import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_events/event_bus.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayu_profile/ayu_profile.dart';
import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:ayu_world/ayu_world.dart';

import 'ayu_lifecycle.dart';
import 'ayu_states.dart';
import 'events/server_started_event.dart';
import 'plugin_console_command.dart';
import 'src/runtime_config.dart';
import 'src/world_columns.dart';

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

  /// Authoritative runtime configuration. Owned and written only here.
  late final RuntimeConfigService config;
  bool _configReady = false;
  ProtocolEndpoint? network;
  WorldEngine? world;
  WorldColumnSource? _columns;

  StreamSubscription<RegistryChange>? _registrySubscription;
  final Map<String, Map<String, List<String>>> _mirrored = {};

  Future<void> start() async {
    lifecycle.setState(ServerState.starting);
    layout = ServerLayout(rootDirectory);
    await layout.create();
    config = RuntimeConfigService(
      file: layout.serverConfigFile,
      log: (message) => logger.warn(message),
    );
    _registerConfigAppliers();
    await config.load();
    _configReady = true;
    profile = await _resolveProfile();
    logger.info(
      'Profile ${profile.id} (Minecraft ${profile.gameVersion}, protocol ${profile.protocolVersion}).',
    );
    plugins = PluginHost(
      rootDirectory: rootDirectory,
      profileId: profile.id,
      options: pluginOptions,
      runtimeExecutable: pluginRuntimeExecutable,
      logger: Logger('Plugins'),
    );
    logger.info('Server starting...');
    _registerBuiltinCommands();
    _registrySubscription = plugins.registry.changes.listen(
      _mirrorPluginCommand,
    );
    await plugins.start();
    await _openWorld();
    await _listen();
    final activePacks = plugins.eventPacks
        .where((pack) => pack.state == PluginState.active)
        .map((pack) => pack.id)
        .toList();
    if (activePacks.isEmpty) {
      logger.info('Server started. No gameplay event packs are active.');
    } else {
      logger.info(
        'Server started. Active event packs: ${activePacks.join(', ')}.',
      );
    }
    events.emit(ServerStartedEvent());
    lifecycle.setState(ServerState.running);
  }

  Future<void> stop() async {
    lifecycle.setState(ServerState.stopping);
    logger.info('Server stopping...');
    await network?.close();
    network = null;
    _columns?.close();
    _columns = null;
    await world?.close();
    world = null;
    await plugins.dispose();
    await _registrySubscription?.cancel();
    // Guaranteed final save: coalesced edits reach disk even if the process
    // is stopped right after the last arrow key.
    if (_configReady) {
      try {
        await config.flush();
      } catch (error) {
        logger.error('configuration could not be saved: $error');
      }
    }
    logger.warn('Server stopped.');
    lifecycle.setState(ServerState.stopped);
  }

  Future<void> _openWorld() async {
    final chunks = _chunkConfig();
    final worldDir = Directory(
      '${layout.worlds.path}${Platform.pathSeparator}overworld',
    );
    final generator = WorldProfile.generatorFor(worldDir);
    final seed = WorldProfile.seedFor(worldDir, configured: _worldSeed());
    final plan = resolveWorkerPlan(
      requested: chunks.workers,
      heavy: generator.heavy,
      maxWorkers: chunks.maxWorkers,
    );
    logger.info(
      'Chunk workers: ${plan.mode.name} count=${plan.count}. ${plan.reason}',
    );
    if (generator.heavy && plan.count == 0) {
      logger.warn(
        'CPU-heavy generator ${generator.id} is running on the engine isolate.',
      );
    }
    world = await WorldEngine.open(
      worldDir: worldDir,
      generator: generator,
      seed: seed,
      encode: (x, z, payload) => encodeChunkColumn(
        chunkX: x,
        chunkZ: z,
        primaryBitmask: payload.primaryBitmask,
        sections: payload.sections,
        biomes: payload.biomes,
        skylight: payload.skylight,
      ),
      config: chunks,
    );
    final opened = world!;
    logger.info(
      'World ${opened.profile.worldId} generator=${opened.profile.generatorId} '
      'v${opened.profile.generatorVersion} seed=${opened.profile.seed}',
    );
    if (opened.spawnFallback) {
      logger.warn(
        'Spawn used the origin fallback at '
        '(${opened.spawn.feetX}, ${opened.spawn.feetY}, ${opened.spawn.feetZ}).',
      );
    }
    _columns = WorldColumnSource(opened);
    _publishReadOnlyFacts();
  }

  /// Static world identity. These are not hot settings: changing them would
  /// silently rewrite chunk data, so the configuration center only displays
  /// them.
  void _publishReadOnlyFacts() {
    final opened = world;
    if (opened == null) return;
    config.readOnlyFacts = {
      'worldId': opened.profile.worldId,
      'generatorId': opened.profile.generatorId,
      'generatorVersion': opened.profile.generatorVersion,
      'seed': opened.profile.seed,
      'storage': opened.profile.storage,
      'spawn': {
        'x': opened.spawn.feetX,
        'y': opened.spawn.feetY,
        'z': opened.spawn.feetZ,
        'fallback': opened.spawnFallback,
      },
      'workers': {
        'mode': opened.workerPlan.mode.name,
        'count': opened.workerPlan.count,
        'reason': opened.workerPlan.reason,
      },
    };
  }

  Future<void> _listen() async {
    final net = _networkConfig();
    final chunks = _chunkConfig();
    final current = world;
    final spawn = current?.spawn ?? FlatStonePadGenerator.padSpawn;
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC ${profile.gameVersion}',
      protocolVersion: profile.protocolVersion,
      description: 'AyuMC ${profile.id}',
      visibility: net.allVisible
          ? const AllSessionsVisible()
          : ViewDistanceVisibility(serverChunks: net.viewChunks),
      entityUpdateInterval: Duration(milliseconds: net.entityUpdateMillis),
      columns: _columns,
      onTick: current == null
          ? null
          : () {
              current.tick();
              // Pressure scales the configured budget instead of overwriting
              // it, so a live configuration change survives a busy moment.
              final pressure = current.pipeline.probe.pressure;
              network?.chunkSendPressureScale = switch (pressure) {
                Pressure.critical => 0.25,
                Pressure.degraded => 0.5,
                Pressure.normal => 1.0,
              };
            },
      terrainChunks: net.viewChunks,
      chunkSendSliceBytes: chunks.sendSliceBytes,
      chunkSendIntervalMillis: chunks.sendIntervalMillis,
      chunkGlobalSendBytes: chunks.globalSendBytes,
      perPlayerPendingChunks: chunks.perPlayerPendingChunks,
      perPlayerQueuedBytes: chunks.perPlayerQueuedBytes,
      compressionThreshold: chunks.compressionThreshold,
      onColumnDelivered: current?.pipeline.noteDeliveryWait,
      spawnFeetX: spawn.feetX,
      spawnFeetY: spawn.feetY,
      spawnFeetZ: spawn.feetZ,
      spawnBlockX: spawn.blockX,
      spawnBlockY: spawn.blockY,
      spawnBlockZ: spawn.blockZ,
      levelType: spawn.levelType,
      interestedIn: (id) =>
          plugins.primitives.hasObservers(id) ||
          plugins.primitives.hasDeciders(id),
      onPrimitive: (id, data) {
        if (plugins.primitives.hasDeciders(id)) {
          unawaited(plugins.primitives.decide(id, data));
        } else if (plugins.primitives.hasObservers(id)) {
          plugins.primitives.observe(id, data);
        }
      },
    );
    try {
      await endpoint.bind(port: net.port);
      network = endpoint;
      if (current != null) {
        current.pipeline.stats.viewChunks = net.viewChunks;
      }
      logger.info(
        'Listening for Minecraft ${profile.gameVersion} on ${endpoint.port}.',
      );
    } on SocketException catch (e) {
      logger.error(
        'Minecraft listener was not started: ${e.message}. Plugins keep running.',
      );
    }
  }

  _NetworkConfig _networkConfig() => _NetworkConfig(
    port: config.value('port'),
    entityUpdateMillis: config.value('entityUpdateMillis'),
    viewChunks: config.value('viewChunks'),
    allVisible: config.value('visibility') == 1,
  );

  ChunkConfig _chunkConfig() => ChunkConfig(
    workers: config.value('chunks.workers'),
    maxWorkers: config.value('chunks.maxWorkers'),
    cacheMiB: config.value('chunks.cacheMiB'),
    sendSliceBytes: config.value('chunks.sendSliceBytes'),
    queuedSoft: config.value('chunks.queuedSoft'),
    queuedHard: config.value('chunks.queuedHard'),
    perPlayerInFlight: config.value('chunks.perPlayerInFlight'),
    p0Bonus: config.value('chunks.p0Bonus'),
    diskReads: config.value('chunks.diskReads'),
    diskFlushes: config.value('chunks.diskFlushes'),
    pregenTickets: config.value('chunks.pregenTickets'),
    pregenInFlightBusy: config.value('chunks.pregenInFlightBusy'),
    pregenInFlightIdle: config.value('chunks.pregenInFlightIdle'),
    inlineBudget: Duration(
      microseconds: config.value('chunks.inlineBudgetMicros'),
    ),
    globalQueuedChunkBytes: config.value('chunks.globalQueuedChunkBytes'),
    workerSubmitQueue: config.value('chunks.workerSubmitQueue'),
    transferableBytes: config.value('chunks.transferableBytes'),
    writeQueueBytes: config.value('chunks.writeQueueBytes'),
    groupCommitChunks: config.value('chunks.groupCommitChunks'),
    groupCommit: Duration(milliseconds: config.value('chunks.groupCommitMillis')),
    globalGenerationInFlight: config.value('chunks.globalGenerationInFlight'),
    viewChunks: config.value('viewChunks'),
    compressionThreshold: config.value('compressionThreshold'),
    sendIntervalMillis: config.value('chunks.sendIntervalMillis'),
    globalSendBytes: config.value('chunks.globalSendBytes'),
    perPlayerPendingChunks: config.value('chunks.perPlayerPendingChunks'),
    perPlayerQueuedBytes: config.value('chunks.perPlayerQueuedBytes'),
  );

  String? _worldSeed() {
    final raw = config.raw('world.seed');
    return raw == null ? null : '$raw';
  }

  /// Registers the engine component that applies each live setting.
  ///
  /// A path without an applier is rejected by [RuntimeConfigService.apply]
  /// unless its spec is restart-scoped, so the configuration screen can never
  /// report a live change that did not take effect.
  void _registerConfigAppliers() {
    config.on('viewChunks', _applyViewChunks);
    config
      ..on('chunks.sendSliceBytes', (value) {
        network?.chunkSendSliceBytes = value;
      })
      ..on('chunks.sendIntervalMillis', (value) {
        network?.setChunkSendInterval(value);
      })
      ..on('chunks.globalSendBytes', (value) {
        network?.chunkGlobalSendBytes = value;
      })
      ..on('chunks.perPlayerPendingChunks', (value) {
        network?.perPlayerPendingChunks = value;
      })
      ..on('chunks.perPlayerQueuedBytes', (value) {
        network?.perPlayerQueuedBytes = value;
      })
      ..on('compressionThreshold', (value) {
        network?.compressionThreshold = value;
      })
      ..on('chunks.perPlayerInFlight', (value) {
        _tune('perPlayerInFlight', value);
      })
      ..on('chunks.p0Bonus', (value) => _tune('p0Bonus', value))
      ..on('chunks.queuedSoft', (value) => _tune('queuedSoft', value))
      ..on('chunks.queuedHard', (value) => _tune('queuedHard', value))
      ..on('chunks.globalQueuedChunkBytes', (value) {
        _tune('globalQueuedChunkBytes', value);
      })
      ..on('chunks.pregenTickets', (value) => _tune('pregenTickets', value))
      ..on('chunks.pregenInFlightBusy', (value) {
        _tune('pregenInFlightBusy', value);
      })
      ..on('chunks.pregenInFlightIdle', (value) {
        _tune('pregenInFlightIdle', value);
      })
      ..on('chunks.cacheMiB', (value) => _tune('cacheMiB', value))
      ..on('chunks.diskReads', (value) => _tune('diskReads', value))
      ..on('chunks.diskFlushes', (value) => _tune('diskFlushes', value))
      ..on('chunks.writeQueueBytes', (value) {
        _tune('writeQueueBytes', value);
      })
      ..on('chunks.groupCommitChunks', (value) {
        _tune('groupCommitChunks', value);
      })
      ..on('chunks.groupCommitMillis', (value) {
        _tune('groupCommitMillis', value);
      })
      ..on('chunks.globalGenerationInFlight', (value) {
        _tune('globalGenerationInFlight', value);
      })
      ..on('chunks.inlineBudgetMicros', (value) {
        _tune('inlineBudgetMicros', value);
      })
      ..on('chunks.workerSubmitQueue', (value) {
        world?.pipeline.setWorkerSubmitQueue(value);
      })
      ..on('chunks.workers', (value) {
        return _applyWorkerPlan(workers: value);
      })
      ..on('chunks.maxWorkers', (value) {
        return _applyWorkerPlan(maxWorkers: value);
      });
  }

  void _tune(String key, int value) {
    final current = world;
    if (current == null) return;
    final previous = current.applyTuning(key, value);
    if (previous == null) {
      throw StateError('the pipeline does not know the tuning key "$key"');
    }
  }

  /// Live view-distance change with per-client reconciliation.
  void _applyViewChunks(int value) {
    final endpoint = network;
    if (endpoint == null) return;
    endpoint.updateViewDistance(value);
    final current = world;
    if (current != null) current.pipeline.stats.viewChunks = value;
    logger.info(
      'Server view cap is now $value chunks; connected clients were '
      'reconciled.',
    );
  }

  /// Worker pool resize. The new isolates start before the plan is used and
  /// old workers drain instead of losing their job.
  Future<void> _applyWorkerPlan({int? workers, int? maxWorkers}) async {
    final current = world;
    if (current == null) return;
    final requested = workers ?? config.value('chunks.workers');
    final cap = maxWorkers ?? config.value('chunks.maxWorkers');
    final plan = await current.resolveAndApplyWorkers(
      requested: requested,
      maxWorkers: cap,
      transferableBytes: config.value('chunks.transferableBytes'),
      submitQueue: config.value('chunks.workerSubmitQueue'),
    );
    logger.info(
      'Chunk workers: ${plan.mode.name} count=${plan.count}. ${plan.reason}',
    );
  }

  /// Live diagnostics for the configuration screen. Read-only.
  Map<String, Object?> diagnostics() {
    final current = world;
    final endpoint = network;
    return {
      'config': config.describe(),
      'chunks': current?.stats() ?? const <String, Object?>{},
      'network': endpoint?.chunkStats() ?? const <String, Object?>{},
      'views': endpoint?.viewDiagnostics() ?? const <Object?>[],
      'sessions': endpoint?.sessions.length ?? 0,
      'tuning': current?.tuning.snapshot() ?? const <String, int>{},
      'workerPlan': current == null
          ? null
          : {
              'mode': current.workerPlan.mode.name,
              'count': current.workerPlan.count,
              'reason': current.workerPlan.reason,
            },
    };
  }

  Future<ServerProfile> _resolveProfile() async {
    if (profileId != null) {
      final selected = ProfileCatalog.byId(profileId!);
      if (selected == null) {
        throw ProfileException(
          'unknown profile "$profileId"; available: ${ProfileCatalog.all.map((p) => p.id).join(', ')}',
        );
      }
      return selected;
    }
    return ProfileSelection(layout.serverConfigFile).load();
  }

  void _registerBuiltinCommands() {
    commands.register(
      Command(
        name: 'ping',
        description: 'Test command',
        execute: (_) => logger.info('pong!'),
      ),
    );
    commands.register(
      Command(
        name: 'say',
        description: 'Broadcast message',
        execute: (args) => logger.info(args.join(' ')),
      ),
    );
    commands.register(
      Command(
        name: 'pregen',
        description:
            'Start, pause, resume, cancel, or show built-in pre-generation.',
        execute: _pregen,
      ),
    );
    commands.register(
      PackageConsoleCommand(plugins, logger, eventPacks: false).command,
    );
    commands.register(
      PackageConsoleCommand(plugins, logger, eventPacks: true).command,
    );
    commands.register(
      Command(
        name: 'profile',
        description: 'Show or select the server profile.',
        execute: _profile,
      ),
    );
    commands.register(
      Command(
        name: 'contracts',
        description: 'List event contracts and their providers.',
        execute: (_) => _contracts(),
      ),
    );
  }

  void _pregen(List<String> args) {
    final current = world;
    if (current == null) {
      logger.warn('world is not open');
      return;
    }
    if (args.isEmpty || args.first == 'status') {
      logger.info(current.pregen.statusText());
      return;
    }
    switch (args.first) {
      case 'start':
        final radius = args.length > 1 ? int.tryParse(args[1]) ?? 8 : 8;
        final shape = args.length > 2 && args[2] == 'disk'
            ? PregenShape.disk
            : PregenShape.square;
        final task = current.pregen.start(
          centerX: 0,
          centerZ: 0,
          radius: radius,
          shape: shape,
        );
        logger.info('pregen ${task.id} started radius $radius ${shape.name}');
      case 'pause':
        current.pregen.pause(args.length > 1 ? args[1] : null);
        logger.info('pregen paused');
      case 'resume':
        current.pregen.resume(args.length > 1 ? args[1] : null);
        logger.info('pregen resumed');
      case 'cancel':
        current.pregen.cancel(args.length > 1 ? args[1] : null);
        logger.info('pregen cancelled');
      default:
        logger.info(
          'pregen start [radius] [square|disk] | pause | resume | cancel | status',
        );
    }
  }

  Future<void> _profile(List<String> args) async {
    if (args.isEmpty || args.first == 'list') {
      for (final candidate in ProfileCatalog.all) {
        final mark = candidate.id == profile.id ? '*' : ' ';
        logger.info(
          '$mark ${candidate.id}  Minecraft ${candidate.gameVersion}  protocol ${candidate.protocolVersion}',
        );
      }
      logger.info(
        'active: ${profile.id} (selection in ${layout.serverConfigFile.path} applies on the next start)',
      );
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
      final provider = row.providerId == null
          ? 'no provider'
          : '${row.providerId} ${row.version} (${row.mode!.name})';
      logger.info(
        '${row.id}: $provider; subscribers ${row.subscribers.join(', ')}; required by ${row.requiredBy.join(', ')}',
      );
    }
  }

  void _mirrorPluginCommand(RegistryChange change) {
    switch (change) {
      case CommandRegistered(:final command):
        final exposed = <String>[];
        for (final name in [command.spec.name, ...command.spec.aliases]) {
          if (commands.has(name)) {
            logger.warn(
              'package "${change.pluginId}" command "$name" shadows a built-in and is not exposed on the console',
            );
            continue;
          }
          commands.register(
            Command(
              name: name,
              description:
                  command.spec.description ?? 'Provided by ${change.pluginId}',
              execute: (args) => _runPluginCommand(name, args),
            ),
          );
          exposed.add(name);
        }
        _mirrored.putIfAbsent(change.pluginId, () => {})[command.spec.name] =
            exposed;
      case CommandUnregistered(:final name):
        for (final consoleName
            in _mirrored[change.pluginId]?.remove(name) ?? const <String>[]) {
          commands.unregister(consoleName);
        }
    }
  }

  Future<void> _runPluginCommand(String name, List<String> args) async {
    try {
      final result = await plugins.executeCommand(
        name,
        args,
        sender: 'console',
      );
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

final class _NetworkConfig {
  const _NetworkConfig({
    this.port = 25565,
    this.entityUpdateMillis = 50,
    this.viewChunks = ViewDistanceVisibility.defaultServerChunks,
    this.allVisible = false,
  });

  final int port;
  final int entityUpdateMillis;
  final int viewChunks;
  final bool allVisible;
}
