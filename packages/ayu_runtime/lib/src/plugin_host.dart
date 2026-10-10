import 'dart:async';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';

import 'contract_registry.dart';
import 'dart_runtime.dart';
import 'errors.dart';
import 'event_platform.dart';
import 'host_events.dart';
import 'host_registry.dart';
import 'plugin_instance.dart';
import 'plugin_snapshot.dart';
import 'plugin_state.dart';
import 'plugin_store.dart';
import 'runtime_options.dart';
import 'server_layout.dart';
import 'worker_controller.dart';
import 'worker_launcher.dart';
import 'worker_process.dart';

/// Entry point of the package platform for the server: regular plugins
/// under `plugins/`, event packs under `events/`, one supervised worker per
/// package, and the contract registry that connects them.
///
/// Every operation on a package id is serialised, so a disable cannot
/// interleave with a start. Nothing here blocks the event loop; all waits
/// are bounded by [PluginRuntimeOptions].
final class PluginHost {
  PluginHost({
    required Directory rootDirectory,
    required this.profileId,
    this.options = const PluginRuntimeOptions(),
    Logger? logger,
    DartAotRuntime? runtime,
    this.runtimeExecutable,
    WorkerLauncher launcher = const AotWorkerLauncher(),
    this.hostVersion = '0.1.0',
  })  : _log = logger ?? Logger('Plugins'),
        _runtime = runtime,
        _target = RuntimeTarget.current(),
        apiVersion = Version.parse(IpcProtocol.apiVersion),
        layout = ServerLayout(rootDirectory) {
    _pluginStore = PluginStore(layout.plugins.root, log: _log);
    _eventStore = PluginStore(layout.events.root, log: _log);
    dispatcher = EventDispatcher(registry: contracts, options: options, log: _log, lookup: _lookup);
    primitives = PrimitiveBus(registry: contracts, dispatcher: dispatcher, options: options, log: _log, lookup: _lookup);
    _controller = WorkerController(
      registry: registry,
      contracts: contracts,
      dispatcher: dispatcher,
      primitives: primitives,
      options: options,
      launcher: launcher,
      log: _log,
      hostVersion: hostVersion,
      onStateChanged: _onStateChanged,
      onLog: _events.add,
      onUnexpectedExit: _onUnexpectedExit,
    );
  }

  /// Active server profile; packages must support it.
  final String profileId;
  final PluginRuntimeOptions options;
  final String? runtimeExecutable;
  final String hostVersion;
  final Version apiVersion;
  final ServerLayout layout;
  final HostRegistry registry = HostRegistry();
  final ContractRegistry contracts = ContractRegistry();
  late final EventDispatcher dispatcher;

  /// The core's entry point for internal primitives.
  late final PrimitiveBus primitives;

  final Logger _log;
  final RuntimeTarget _target;
  late final PluginStore _pluginStore;
  late final PluginStore _eventStore;
  late final WorkerController _controller;
  final Map<String, PluginInstance> _instances = {};
  final Map<String, Future<void>> _locks = {};
  final StreamController<PluginHostEvent> _events = StreamController.broadcast();
  DartAotRuntime? _runtime;
  PluginHostException? _runtimeError;
  bool _started = false;
  bool _disposed = false;

  RuntimeTarget get target => _target;
  DartAotRuntime? get runtime => _runtime;
  Stream<PluginHostEvent> get events => _events.stream;

  List<PluginSnapshot> get plugins => [for (final i in _instances.values) _snapshot(i)]..sort((a, b) => a.id.compareTo(b.id));

  List<PluginSnapshot> get eventPacks => plugins.where((p) => p.isEventPack).toList();
  List<PluginSnapshot> get regularPlugins => plugins.where((p) => !p.isEventPack).toList();

  PluginSnapshot? plugin(String id) {
    final instance = _instances[id];
    return instance == null ? null : _snapshot(instance);
  }

  /// Opens both stores, locates the runtime and starts every enabled
  /// package: event packs first, then plugins, each in dependency order. A
  /// missing runtime is not fatal here; it is reported per package and on
  /// the next enable attempt.
  Future<void> start() async {
    if (_started) throw StateError('PluginHost already started');
    _started = true;
    await layout.create();
    await _pluginStore.open();
    await _eventStore.open();
    await _locateRuntime();
    final stored = [
      ...await _eventStore.loadInstalled(limits: options.packageLimits),
      ...await _pluginStore.loadInstalled(limits: options.packageLimits),
    ];
    for (final item in stored) {
      _instances[item.record.id] = PluginInstance(
        manifest: item.manifest,
        installDirectory: item.installDirectory,
        dataDirectory: _storeFor(item.manifest).layout.dataDirectory(item.record.id),
        initialState: PluginState.discovered,
      );
    }
    for (final instance in _instances.values) {
      _move(instance, PluginState.disabled);
    }
    final enabled = stored.where((s) => s.record.enabled).map((s) => s.record.id).toSet();
    final packs = _bootOrder(enabled.where((id) => _instances[id]!.isEventPack).toSet());
    final regular = _bootOrder(enabled.where((id) => !_instances[id]!.isEventPack).toSet());
    for (final id in [...packs, ...regular]) {
      try {
        await _serialized(id, () => _startInstance(_instances[id]!));
      } on PluginHostException catch (e) {
        _log.error('package "$id" was not started: ${e.message}');
      }
    }
  }

  /// Stops every running worker (bounded) and releases resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Plugins first so no consumer sees its providers vanish mid-shutdown.
    final order = [
      ..._instances.values.where((i) => !i.isEventPack),
      ..._instances.values.where((i) => i.isEventPack),
    ];
    for (final instance in order) {
      if (instance.state.hasWorker || instance.worker != null) {
        try {
          await _serialized(instance.id, () => _stopInstance(instance, reason: 'host shutdown', notifyDependents: false));
        } catch (e) {
          _log.error('stopping "${instance.id}" failed: $e');
        }
      }
    }
    dispatcher.dispose();
    primitives.dispose();
    await registry.dispose();
    await _events.close();
  }

  // ------------------------------------------------------------- operations

  /// Installs a plugin or event pack while the server runs. With [enable]
  /// the worker is started; a plugin whose required contracts have no
  /// provider is left `suspended` with diagnostics, a start failure leaves
  /// the package installed in the failed state.
  Future<PluginSnapshot> install(File package, {bool enable = true}) async {
    _checkUsable();
    final opened = await AyuPackage.open(package, limits: options.packageLimits);
    try {
      final manifest = opened.manifest;
      _checkCompatibility(manifest);
      return await _serialized(manifest.id, () async {
        if (_instances.containsKey(manifest.id)) {
          throw PluginHostException(PluginHostErrorCode.alreadyInstalled,
              'package "${manifest.id}" ${_instances[manifest.id]!.version} is already installed; use update to replace it');
        }
        _checkDependencies(manifest, requireActive: enable);
        final store = _storeFor(manifest);
        final installDirectory = await _stage(store, opened);
        final instance = PluginInstance(
          manifest: manifest,
          installDirectory: installDirectory,
          dataDirectory: store.layout.dataDirectory(manifest.id),
          initialState: PluginState.staged,
        );
        _instances[manifest.id] = instance;
        _emit(PluginStateChanged(manifest.id, PluginState.validating, PluginState.staged));
        await store.put(InstalledPluginRecord(id: manifest.id, version: manifest.version, enabled: enable));
        try {
          if (enable) {
            await _startInstance(instance);
          } else {
            _move(instance, PluginState.disabled);
          }
        } on PluginHostException {
          if (instance.state == PluginState.staged) {
            _instances.remove(manifest.id);
            await store.remove(manifest.id);
            await store.deleteInstalled(manifest.id, manifest.version);
          }
          rethrow;
        }
        return _snapshot(instance);
      });
    } finally {
      await opened.close();
    }
  }

  Future<PluginSnapshot> enable(String id) {
    _checkUsable();
    return _serialized(id, () async {
      final instance = _require(id);
      if (instance.state == PluginState.active) return _snapshot(instance);
      if (instance.state.hasWorker) {
        throw PluginHostException(PluginHostErrorCode.invalidState, 'package "$id" is ${instance.state.name}');
      }
      final store = _storeFor(instance.manifest);
      await store.put(store.records[id]!.copyWith(enabled: true));
      await _startInstance(instance);
      return _snapshot(instance);
    });
  }

  /// Stops routing immediately, then shuts the worker down (killing it if
  /// it ignores the request). Disabling an event pack whose contracts are
  /// required by active plugins is refused unless [cascade] suspends them.
  Future<PluginSnapshot> disable(String id, {String reason = 'requested', bool cascade = false}) {
    _checkUsable();
    return _serialized(id, () async {
      final instance = _require(id);
      if (instance.state == PluginState.disabled) return _snapshot(instance);
      _checkNoActiveDependents(id);
      if (instance.isEventPack && !cascade) _checkNoActiveContractDependents(instance);
      final store = _storeFor(instance.manifest);
      await store.put(store.records[id]!.copyWith(enabled: false));
      if (instance.state.hasWorker || instance.worker != null) {
        await _stopInstance(instance, reason: reason);
      } else {
        _move(instance, PluginState.disabled);
      }
      return _snapshot(instance);
    });
  }

  /// Replaces an installed package with a different version. The new
  /// version is staged next to the old one; the old worker is stopped only
  /// after staging succeeded, and restarted if the new version fails.
  Future<PluginSnapshot> update(File package) async {
    _checkUsable();
    final opened = await AyuPackage.open(package, limits: options.packageLimits);
    try {
      final manifest = opened.manifest;
      _checkCompatibility(manifest);
      return await _serialized(manifest.id, () async {
        final current = _require(manifest.id);
        if (current.version == manifest.version) {
          throw PluginHostException(PluginHostErrorCode.alreadyInstalled,
              'package "${manifest.id}" ${manifest.version} is already the installed version');
        }
        if (current.manifest.packageType != manifest.packageType) {
          throw PluginHostException(PluginHostErrorCode.incompatible,
              'package "${manifest.id}" is installed as a ${current.manifest.packageType.wireName}; the update is a ${manifest.packageType.wireName}');
        }
        final store = _storeFor(manifest);
        final record = store.records[manifest.id]!;
        final wasActive = current.state == PluginState.active;
        _checkDependencies(manifest, requireActive: wasActive);
        _checkDependentsAccept(manifest.id, manifest.version);
        final installDirectory = await _stage(store, opened);
        final next = PluginInstance(
          manifest: manifest,
          installDirectory: installDirectory,
          dataDirectory: current.dataDirectory,
          initialState: PluginState.staged,
        );
        if (current.state.hasWorker || current.worker != null) {
          await _stopInstance(current, reason: 'update to ${manifest.version}');
        }
        _instances[manifest.id] = next;
        _emit(PluginStateChanged(manifest.id, PluginState.validating, PluginState.staged));
        await store.put(record.copyWith(version: manifest.version));
        if (!wasActive) {
          _move(next, PluginState.disabled);
          await store.deleteInstalled(manifest.id, current.version);
          return _snapshot(next);
        }
        try {
          await _startInstance(next);
        } on PluginHostException catch (failure) {
          _log.error('update of "${manifest.id}" to ${manifest.version} failed; rolling back to ${current.version}');
          _instances[manifest.id] = current;
          await store.put(record);
          await store.deleteInstalled(manifest.id, manifest.version);
          final details = [failure.message, ...failure.details];
          try {
            await _startInstance(current);
          } on PluginHostException catch (rollbackFailure) {
            details.add('rollback failed: ${rollbackFailure.message}');
          }
          throw PluginHostException(PluginHostErrorCode.updateFailed,
              'update of "${manifest.id}" to ${manifest.version} failed; ${current.version} restored',
              details: details);
        }
        await store.deleteInstalled(manifest.id, current.version);
        return _snapshot(next);
      });
    } finally {
      await opened.close();
    }
  }

  /// Stops the package if needed and removes its installed files. The data
  /// directory is kept. Refused while other installed packages depend on
  /// it, or (event packs) while active plugins require its contracts unless
  /// [cascade] suspends them.
  Future<void> uninstall(String id, {bool cascade = false}) {
    _checkUsable();
    return _serialized(id, () async {
      final instance = _require(id);
      final dependents = _dependentsOf(id, onlyActive: false);
      if (dependents.isNotEmpty) {
        throw PluginHostException(PluginHostErrorCode.dependency,
            'cannot uninstall "$id": required by ${dependents.join(', ')}');
      }
      if (instance.isEventPack && !cascade) _checkNoActiveContractDependents(instance);
      if (instance.state.hasWorker || instance.worker != null) {
        await _stopInstance(instance, reason: 'uninstall');
      }
      final store = _storeFor(instance.manifest);
      _instances.remove(id);
      await store.remove(id);
      await store.deleteInstalled(id, instance.version);
      _log.info('uninstalled "$id" ${instance.version}');
    });
  }

  /// Executes a plugin command. Throws [PluginHostException] when the
  /// command is unknown, its plugin is not active, or the worker fails.
  Future<CommandResult> executeCommand(String nameOrAlias, List<String> args, {String sender = 'console'}) async {
    final registered = registry.resolveCommand(nameOrAlias);
    if (registered == null) {
      throw PluginHostException(PluginHostErrorCode.commandNotFound, 'unknown command "$nameOrAlias"');
    }
    final instance = _instances[registered.pluginId];
    final worker = instance?.worker;
    if (instance == null || worker == null || instance.state != PluginState.active) {
      throw PluginHostException(PluginHostErrorCode.commandFailed,
          'command "$nameOrAlias" belongs to "${registered.pluginId}", which is not active');
    }
    try {
      final result = await worker.channel.request(
        IpcMethod.commandExecute,
        CommandInvocation(name: registered.spec.name, args: args, sender: sender).toJson(),
        options.commandTimeout,
      );
      return CommandResult.fromJson(result);
    } on IpcException catch (e) {
      throw PluginHostException(PluginHostErrorCode.commandFailed,
          'command "$nameOrAlias" failed in plugin "${registered.pluginId}": ${e.error}');
    }
  }

  // --------------------------------------------------------------- internals

  PluginInstance? _lookup(String id) => _instances[id];

  PluginStore _storeFor(PluginManifest manifest) => manifest.isEventPack ? _eventStore : _pluginStore;

  Future<void> _locateRuntime() async {
    if (_runtime != null) return;
    try {
      _runtime = await const DartRuntimeLocator().locate(explicitPath: runtimeExecutable);
      _log.info('using ${_runtime!}');
    } on PluginHostException catch (e) {
      _runtimeError = e;
      _log.error(e.toString());
    }
  }

  DartAotRuntime _requireRuntime() {
    final runtime = _runtime;
    if (runtime == null) {
      throw _runtimeError ??
          const PluginHostException(PluginHostErrorCode.runtimeUnavailable, 'plugin runtime is not available');
    }
    return runtime;
  }

  /// Starts a worker. Plugins whose required contracts are unavailable are
  /// parked in `suspended` instead; event packs whose contracts collide
  /// with an active provider are refused.
  Future<void> _startInstance(PluginInstance instance) async {
    final runtime = _requireRuntime();
    _checkArtifactCompatibility(instance.manifest, runtime);
    _checkDependencies(instance.manifest, requireActive: true);
    if (instance.isEventPack) {
      final conflicts = contracts.conflictsFor(instance.id, instance.manifest.provides);
      if (conflicts.isNotEmpty) {
        throw PluginHostException(PluginHostErrorCode.conflict,
            'event pack "${instance.id}" cannot start: contract(s) already provided', details: conflicts);
      }
    } else {
      final unsatisfied = contracts.unsatisfiedRequirements(instance.manifest);
      if (unsatisfied.isNotEmpty) {
        instance.lastError = 'waiting for required contracts: ${unsatisfied.join('; ')}';
        if (instance.state != PluginState.suspended) _move(instance, PluginState.suspended, error: instance.lastError);
        _log.warn('[${instance.id}] ${instance.lastError}');
        return;
      }
    }
    await _controller.start(instance, runtime);
    if (instance.isEventPack) {
      contracts.registerProvider(instance.id, instance.manifest.provides);
      instance.providerRegistered = true;
      await _onContractsAvailable(instance.manifest.provides.map((c) => c.id).toList(), instance.id);
    }
  }

  /// Stops a worker; for event packs the contracts are withdrawn first so
  /// nothing is published mid-shutdown, then dependents are handled.
  Future<TerminationOutcome> _stopInstance(PluginInstance instance,
      {required String reason, PluginState endState = PluginState.disabled, bool notifyDependents = true}) async {
    var lost = const <String>[];
    if (instance.isEventPack && instance.providerRegistered) {
      lost = contracts.unregisterProvider(instance.id);
      instance.providerRegistered = false;
    }
    final outcome = await _controller.stop(instance, reason: reason, endState: endState);
    if (lost.isNotEmpty && notifyDependents) {
      await _onContractsLost(lost, '"${instance.id}" ${reason == 'requested' ? 'was disabled' : reason}');
    }
    return outcome;
  }

  /// Required dependents are suspended; optional consumers are told.
  Future<void> _onContractsLost(List<String> lost, String cause) async {
    final suspensions = <Future<void>>[];
    for (final id in contracts.consumersRequiring(lost)) {
      final dependent = _instances[id];
      if (dependent == null || dependent.state != PluginState.active) continue;
      final missing = lost.where((c) => dependent.manifest.requiredEvents.any((r) => r.id == c)).join(', ');
      dependent.lastError = 'required contract(s) $missing unavailable: $cause';
      _log.warn('[${dependent.id}] suspending: ${dependent.lastError}');
      suspensions.add(_serialized(id, () async {
        if (dependent.state != PluginState.active) return;
        await _controller.stop(dependent, reason: 'required contract unavailable', endState: PluginState.suspended);
      }));
    }
    await Future.wait(suspensions);
    for (final id in contracts.consumersOptionallyUsing(lost)) {
      final consumer = _instances[id];
      final worker = consumer?.worker;
      if (consumer == null || worker == null || consumer.state != PluginState.active) continue;
      for (final contract in lost) {
        if (consumer.manifest.optionalEvents.any((o) => o.id == contract)) {
          worker.channel.notify(IpcMethod.contractChanged, ContractAvailability(id: contract, available: false).toJson());
        }
      }
    }
  }

  /// Optional consumers are told; suspended plugins whose requirements are
  /// now met are started again.
  Future<void> _onContractsAvailable(List<String> available, String providerId) async {
    for (final id in contracts.consumersOptionallyUsing(available)) {
      final consumer = _instances[id];
      final worker = consumer?.worker;
      if (consumer == null || worker == null || consumer.state != PluginState.active) continue;
      for (final contract in available) {
        final provided = contracts.provider(contract);
        if (provided != null && consumer.manifest.optionalEvents.any((o) => o.id == contract)) {
          worker.channel.notify(IpcMethod.contractChanged,
              ContractAvailability(id: contract, available: true, version: provided.spec.version.toString()).toJson());
        }
      }
    }
    final resumes = <Future<void>>[];
    for (final candidate in _instances.values.where((i) => i.state == PluginState.suspended).toList()) {
      final store = _storeFor(candidate.manifest);
      if (store.records[candidate.id]?.enabled != true) continue;
      if (contracts.unsatisfiedRequirements(candidate.manifest).isNotEmpty) continue;
      _log.info('[${candidate.id}] required contracts available again (from "$providerId"); resuming');
      resumes.add(_serialized(candidate.id, () async {
        if (candidate.state != PluginState.suspended) return;
        try {
          await _startInstance(candidate);
        } on PluginHostException catch (e) {
          _log.error('resume of "${candidate.id}" failed: ${e.message}');
        }
      }));
    }
    await Future.wait(resumes);
  }

  /// Extracts the opened package into staging, then commits it atomically.
  Future<Directory> _stage(PluginStore store, AyuPackage package) async {
    final staging = await store.createStagingDirectory();
    try {
      await package.extractTo(staging);
    } catch (_) {
      await store.discard(staging);
      rethrow;
    }
    return store.commit(staged: staging, id: package.manifest.id, version: package.manifest.version);
  }

  /// Rejects packages this host cannot run, with the reason spelled out.
  void _checkCompatibility(PluginManifest manifest) {
    if (!manifest.api.allows(apiVersion)) {
      throw PluginHostException(PluginHostErrorCode.incompatible,
          'package "${manifest.id}" requires plugin API ${manifest.api}; this host provides $apiVersion');
    }
    if (!manifest.supportsProfile(profileId)) {
      throw PluginHostException(PluginHostErrorCode.incompatible,
          'package "${manifest.id}" supports profile(s) ${manifest.profiles.join(', ')}; this server runs $profileId');
    }
    final runtime = _runtime;
    if (runtime != null) {
      _checkArtifactCompatibility(manifest, runtime);
    } else if (manifest.artifactFor(_target) == null) {
      throw _noArtifact(manifest);
    }
  }

  void _checkArtifactCompatibility(PluginManifest manifest, DartAotRuntime runtime) {
    final artifact = manifest.artifactFor(runtime.target);
    if (artifact == null) throw _noArtifact(manifest);
    if (artifact.dartSdk != runtime.version) {
      throw PluginHostException(PluginHostErrorCode.incompatible,
          'package "${manifest.id}" artifact for ${runtime.target} was built with Dart ${artifact.dartSdk}; '
          'this server runs dartaotruntime ${runtime.version}. AOT snapshots only run on the exact SDK version '
          'that produced them: rebuild the package with Dart ${runtime.version}.');
    }
  }

  PluginHostException _noArtifact(PluginManifest manifest) => PluginHostException(
        PluginHostErrorCode.incompatible,
        'package "${manifest.id}" has no runtime artifact for ${_target.id}'
        '${manifest.artifacts.isEmpty ? ' (source-only package)' : '; it ships ${manifest.artifacts.keys.join(', ')}'}. '
        'Build it with `ayu plugin build --target ${_target.id}` and repackage.',
      );

  void _checkDependencies(PluginManifest manifest, {required bool requireActive}) {
    final problems = <String>[];
    for (final dependency in manifest.dependencies) {
      final installed = _instances[dependency.id];
      if (installed == null) {
        if (!dependency.optional) problems.add('"${dependency.id}" ${dependency.version} is not installed');
        continue;
      }
      if (!dependency.version.allows(installed.version)) {
        if (!dependency.optional) {
          problems.add('"${dependency.id}" ${installed.version} is installed but ${dependency.version} is required');
        }
        continue;
      }
      if (requireActive && !dependency.optional && installed.state != PluginState.active) {
        problems.add('"${dependency.id}" is ${installed.state.name}; enable it first');
      }
    }
    if (problems.isNotEmpty) {
      throw PluginHostException(PluginHostErrorCode.dependency,
          'package "${manifest.id}" has unsatisfied dependencies', details: problems);
    }
  }

  void _checkNoActiveDependents(String id) {
    final dependents = _dependentsOf(id, onlyActive: true);
    if (dependents.isNotEmpty) {
      throw PluginHostException(PluginHostErrorCode.dependency,
          'cannot disable "$id": required by active package(s) ${dependents.join(', ')}; disable them first');
    }
  }

  void _checkNoActiveContractDependents(PluginInstance pack) {
    final provided = pack.manifest.provides.map((c) => c.id).toList();
    final dependents = [
      for (final id in contracts.consumersRequiring(provided))
        if (_instances[id]?.state == PluginState.active) id,
    ];
    if (dependents.isNotEmpty) {
      throw PluginHostException(PluginHostErrorCode.dependency,
          'event pack "${pack.id}" provides contracts required by active plugin(s) ${dependents.join(', ')}; '
          'disable them first or pass --cascade to suspend them');
    }
  }

  /// Before an update, every dependent's constraint must accept the new
  /// version, otherwise the dependent would break silently.
  void _checkDependentsAccept(String id, Version next) {
    final rejecting = <String>[
      for (final other in _instances.values)
        for (final dependency in other.manifest.requiredDependencies)
          if (dependency.id == id && !dependency.version.allows(next)) '"${other.id}" requires $id ${dependency.version}',
    ];
    if (rejecting.isNotEmpty) {
      throw PluginHostException(PluginHostErrorCode.dependency, 'cannot update "$id" to $next', details: rejecting);
    }
  }

  List<String> _dependentsOf(String id, {required bool onlyActive}) => [
        for (final other in _instances.values)
          if (other.id != id &&
              (!onlyActive || other.state == PluginState.active) &&
              other.manifest.requiredDependencies.any((d) => d.id == id))
            other.id,
      ];

  /// Topological order over required package dependencies; members of a
  /// cycle are reported and skipped.
  List<String> _bootOrder(Set<String> ids) {
    final remaining = Set.of(ids);
    final order = <String>[];
    while (remaining.isNotEmpty) {
      final ready = remaining.where((id) {
        final deps = _instances[id]!.manifest.requiredDependencies.map((d) => d.id);
        return deps.every((d) => !remaining.contains(d));
      }).toList()
        ..sort();
      if (ready.isEmpty) {
        for (final id in remaining) {
          final instance = _instances[id]!;
          instance.lastError = 'dependency cycle involving ${remaining.join(', ')}';
          _log.error('package "$id" not started: ${instance.lastError}');
        }
        break;
      }
      order.addAll(ready);
      remaining.removeAll(ready);
    }
    return order;
  }

  void _onUnexpectedExit(PluginInstance instance, int exitCode) {
    unawaited(_serialized(instance.id, () async {
      final worker = instance.worker;
      if (worker == null || instance.state != PluginState.active) return;
      var lost = const <String>[];
      if (instance.isEventPack && instance.providerRegistered) {
        lost = contracts.unregisterProvider(instance.id);
        instance.providerRegistered = false;
      }
      _controller.releaseRegistrations(instance);
      instance.recordWorkerFailure(worker, 'worker exited unexpectedly with code $exitCode');
      await worker.dispose();
      instance.worker = null;
      _move(instance, PluginState.crashed, error: instance.lastError);
      if (lost.isNotEmpty) _onContractsLost(lost, '"${instance.id}" crashed');
      if (!options.restartOnCrash) return;
      final allowed = instance.consumeRestartBudget(
          maxRestarts: options.maxRestarts, window: options.restartWindow, now: DateTime.now());
      if (!allowed) {
        _log.error('package "${instance.id}" crashed ${options.maxRestarts} times within '
            '${options.restartWindow.inSeconds}s; leaving it crashed');
        return;
      }
      _log.warn('restarting "${instance.id}" after crash (${instance.restartTimes.length}/${options.maxRestarts})');
      try {
        await _startInstance(instance);
      } on PluginHostException catch (e) {
        _log.error('restart of "${instance.id}" failed: ${e.message}');
      }
    }));
  }

  void _onStateChanged(PluginInstance instance, PluginState from, PluginState to, {String? error}) {
    _log.info('[${instance.id}] ${from.name} -> ${to.name}${error == null ? '' : ': $error'}');
    _emit(PluginStateChanged(instance.id, from, to, error: error));
  }

  void _move(PluginInstance instance, PluginState to, {String? error}) {
    final from = instance.transition(to);
    _onStateChanged(instance, from, to, error: error);
  }

  void _emit(PluginHostEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  PluginInstance _require(String id) {
    final instance = _instances[id];
    if (instance == null) {
      throw PluginHostException(PluginHostErrorCode.notInstalled, 'package "$id" is not installed');
    }
    return instance;
  }

  PluginSnapshot _snapshot(PluginInstance instance) =>
      instance.snapshot(enabled: _storeFor(instance.manifest).records[instance.id]?.enabled ?? false);

  void _checkUsable() {
    if (!_started) throw StateError('PluginHost.start() has not been called');
    if (_disposed) throw StateError('PluginHost is disposed');
  }

  /// Runs [action] after every earlier operation on [id] finished.
  Future<T> _serialized<T>(String id, Future<T> Function() action) {
    final previous = _locks[id] ?? Future<void>.value();
    final completer = Completer<void>();
    _locks[id] = completer.future;
    return previous.then((_) => action()).whenComplete(() {
      completer.complete();
      if (identical(_locks[id], completer.future)) _locks.remove(id);
    });
  }
}

/// Exposed for diagnostics: termination outcomes are logged with this name.
extension TerminationOutcomeLabel on TerminationOutcome {
  String get label => switch (this) {
        TerminationOutcome.exitedGracefully => 'exited gracefully',
        TerminationOutcome.killed => 'killed after grace period',
        TerminationOutcome.killFailed => 'kill did not complete',
        TerminationOutcome.alreadyExited => 'already exited',
      };
}
