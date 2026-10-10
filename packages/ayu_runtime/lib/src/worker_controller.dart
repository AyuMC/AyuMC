import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;

import 'contract_registry.dart';
import 'dart_runtime.dart';
import 'errors.dart';
import 'event_platform.dart';
import 'host_events.dart';
import 'host_registry.dart';
import 'plugin_instance.dart';
import 'plugin_state.dart';
import 'runtime_options.dart';
import 'worker_launcher.dart';
import 'worker_process.dart';

/// Starts and stops the worker of one package and serves the requests that
/// worker makes. State transitions on the instance happen here; policy
/// (locks, dependencies, providers, restarts, persistence) lives in
/// `PluginHost`.
final class WorkerController {
  WorkerController({
    required this.registry,
    required this.contracts,
    required this.dispatcher,
    required this.primitives,
    required this.options,
    required this.launcher,
    required this.log,
    required this.hostVersion,
    required this.onStateChanged,
    required this.onLog,
    required this.onUnexpectedExit,
  });

  final HostRegistry registry;
  final ContractRegistry contracts;
  final EventDispatcher dispatcher;
  final PrimitiveBus primitives;
  final PluginRuntimeOptions options;
  final WorkerLauncher launcher;
  final Logger log;
  final String hostVersion;
  final void Function(PluginInstance instance, PluginState from, PluginState to, {String? error}) onStateChanged;
  final void Function(PluginLogged entry) onLog;

  /// Called when an active worker exits without being asked to.
  final void Function(PluginInstance instance, int exitCode) onUnexpectedExit;

  /// Launches the worker, completes the handshake and `init`, and marks the
  /// instance active. On failure the worker is killed, registrations are
  /// removed, the instance is marked failed and a [PluginHostException] is
  /// thrown.
  Future<void> start(PluginInstance instance, DartAotRuntime runtime) async {
    final artifact = instance.manifest.artifactFor(runtime.target);
    if (artifact == null) {
      throw PluginHostException(PluginHostErrorCode.incompatible,
          'package "${instance.id}" has no artifact for ${runtime.target}');
    }
    _move(instance, PluginState.starting);
    WorkerProcess? worker;
    try {
      final spec = launcher.launchSpec(PluginLaunchContext(
        manifest: instance.manifest,
        installDirectory: instance.installDirectory,
        dataDirectory: instance.dataDirectory,
        artifact: artifact,
        runtime: runtime,
      ));
      await instance.dataDirectory.create(recursive: true);
      final config = await loadConfig(instance);
      if (!instance.isEventPack) contracts.declareRequirements(instance.id, instance.manifest.events);
      worker = await WorkerProcess.start(spec,
          options: options, log: log, debugName: instance.id, hostVersion: hostVersion);
      instance.worker = worker;
      final started = worker;
      worker.requestHandler = (method, params) => handleWorkerRequest(instance, method, params);
      worker.notificationHandler = (method, params) {
        _handleNotification(instance, method, params);
      };
      worker.onExit = (code) {
        _handleExit(instance, started, code);
      };

      final hello = await worker.awaitHello();
      log.info('[${instance.id}] worker pid ${worker.pid} online (sdk ${hello.sdkVersion})');
      await worker.init(InitRequest(
        plugin: PluginDescriptor(id: instance.id, name: instance.manifest.name, version: instance.version.toString()),
        installDirectory: instance.installDirectory.path,
        dataDirectory: instance.dataDirectory.path,
        capabilities: instance.manifest.capabilities.toList()..sort(),
        config: config,
      ));
      if (worker.hasExited) {
        throw WorkerStartException('worker exited during initialisation',
            exitCode: worker.exitCode, stderrTail: worker.stderrTail);
      }
      instance.lastError = null;
      _move(instance, PluginState.active);
      if (instance.isEventPack) {
        primitives.attach(instance);
      } else {
        dispatcher.attach(instance);
      }
    } on WorkerStartException catch (e) {
      await _abortStart(instance, worker, e.message, e.exitCode, e.stderrTail);
      throw PluginHostException(PluginHostErrorCode.startFailed, 'package "${instance.id}" failed to start: ${e.message}',
          details: [if (e.exitCode != null) 'exit code ${e.exitCode}', if (e.stderrTail.isNotEmpty) 'stderr: ${e.stderrTail}']);
    } on PluginHostException catch (e) {
      await _abortStart(instance, worker, e.message, null, worker?.stderrTail ?? '');
      rethrow;
    }
  }

  /// Removes registrations first so nothing is routed to the worker while it
  /// shuts down, then terminates it. The instance ends in [endState]
  /// (`disabled` or `suspended`), or `failed` when the kill did not complete.
  Future<TerminationOutcome> stop(PluginInstance instance,
      {required String reason, PluginState endState = PluginState.disabled}) async {
    _move(instance, PluginState.stopping);
    _releaseRegistrations(instance);
    final worker = instance.worker;
    var outcome = TerminationOutcome.alreadyExited;
    if (worker != null) {
      outcome = await worker.terminate(reason: reason);
      instance.lastExitCode = worker.exitCode;
      instance.lastStderrTail = worker.stderrTail;
      await worker.dispose();
      instance.worker = null;
    }
    if (outcome == TerminationOutcome.killFailed) {
      instance.lastError = 'worker pid ${worker!.pid} could not be terminated; it is no longer routed to';
      _move(instance, PluginState.failed, error: instance.lastError);
    } else {
      _move(instance, endState, error: endState == PluginState.suspended ? instance.lastError : null);
    }
    return outcome;
  }

  /// Configuration handed to the package: `data/<id>/config.json` when the
  /// operator created one, otherwise the package's `config/config.json`,
  /// otherwise empty.
  Future<Map<String, Object?>> loadConfig(PluginInstance instance) async {
    final candidates = [
      File(p.join(instance.dataDirectory.path, PackageSpec.defaultConfigFileName)),
      File(p.join(instance.installDirectory.path, PackageSpec.configDirectory, PackageSpec.defaultConfigFileName)),
    ];
    for (final file in candidates) {
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) throw const FormatException('root must be an object');
        return decoded.cast<String, Object?>();
      } on FormatException catch (e) {
        throw PluginHostException(PluginHostErrorCode.configInvalid, '${file.path} is not a JSON object: ${e.message}');
      }
    }
    return const {};
  }

  /// Serves worker -> host requests. Capability checks happen here.
  Future<Object?> handleWorkerRequest(PluginInstance instance, String method, Object? params) async {
    if (instance.state != PluginState.starting && instance.state != PluginState.active) {
      throw IpcException.code(IpcErrorCode.unavailable, 'package is ${instance.state.name}');
    }
    switch (method) {
      case IpcMethod.commandRegister:
        _requireCapability(instance, PluginCapability.commands);
        registry.registerCommand(instance.id, CommandSpec.fromJson(params));
        return null;
      case IpcMethod.commandUnregister:
        _requireCapability(instance, PluginCapability.commands);
        registry.unregisterCommand(instance.id, CommandNameSpec.fromJson(params).name);
        return null;
      case IpcMethod.eventSubscribe:
        _requireCapability(instance, PluginCapability.events);
        contracts.subscribe(instance.id, EventSubscriptionSpec.fromJson(params).type);
        return null;
      case IpcMethod.eventUnsubscribe:
        _requireCapability(instance, PluginCapability.events);
        contracts.unsubscribe(instance.id, EventSubscriptionSpec.fromJson(params).type);
        return null;
      case IpcMethod.observeSubscribe:
        _requireCapability(instance, PluginCapability.observe);
        contracts.subscribePrimitive(instance.id, PrimitiveSubscriptionSpec.fromJson(params).id, instance.manifest);
        return null;
      case IpcMethod.observeUnsubscribe:
        _requireCapability(instance, PluginCapability.observe);
        contracts.unsubscribePrimitive(instance.id, PrimitiveSubscriptionSpec.fromJson(params).id);
        return null;
      case IpcMethod.configGet:
        _requireCapability(instance, PluginCapability.config);
        try {
          return await loadConfig(instance);
        } on PluginHostException catch (e) {
          throw IpcException.code(IpcErrorCode.internal, e.message);
        }
      default:
        throw IpcException.code(IpcErrorCode.methodNotFound, 'host does not implement $method');
    }
  }

  void _handleNotification(PluginInstance instance, String method, Object? params) {
    switch (method) {
      case IpcMethod.log:
        _handleLog(instance, LogNotification.fromJson(params));
      case IpcMethod.eventPublish:
        if (_canPublish(instance)) dispatcher.publish(instance.id, PublishedEvent.fromJson(params));
      case IpcMethod.eventPublishBatch:
        if (_canPublish(instance)) {
          for (final event in PublishedEventBatch.fromJson(params).items) {
            dispatcher.publish(instance.id, event);
          }
        }
    }
  }

  bool _canPublish(PluginInstance instance) {
    if (!instance.manifest.capabilities.contains(PluginCapability.publish)) {
      log.warn('[${instance.id}] published without the "publish" capability; ignored');
      return false;
    }
    return instance.state == PluginState.active && instance.providerRegistered;
  }

  void _handleLog(PluginInstance instance, LogNotification entry) {
    final timestamp = entry.timestampMillis == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(entry.timestampMillis!);
    switch (entry.level) {
      case IpcLogLevel.error:
        log.error('[${instance.id}] ${entry.message}');
      case IpcLogLevel.warn:
        log.warn('[${instance.id}] ${entry.message}');
      default:
        log.info('[${instance.id}] ${entry.message}');
    }
    onLog(PluginLogged(instance.id, entry.level, entry.message, timestamp));
  }

  void _handleExit(PluginInstance instance, WorkerProcess worker, int code) {
    if (!identical(instance.worker, worker)) return;
    if (instance.state != PluginState.active) return;
    onUnexpectedExit(instance, code);
  }

  /// Host-side cleanup that must happen the moment a package leaves the
  /// active state. Provider deregistration is the host's job.
  void releaseRegistrations(PluginInstance instance) => _releaseRegistrations(instance);

  void _releaseRegistrations(PluginInstance instance) {
    registry.removeAll(instance.id);
    if (instance.isEventPack) {
      primitives.detach(instance.id);
    } else {
      contracts.removeConsumer(instance.id);
      dispatcher.detach(instance.id);
    }
  }

  Future<void> _abortStart(
      PluginInstance instance, WorkerProcess? worker, String message, int? exitCode, String stderrTail) async {
    _releaseRegistrations(instance);
    if (worker != null) {
      await worker.kill();
      instance.lastExitCode = worker.exitCode;
      instance.lastStderrTail = worker.stderrTail;
      await worker.dispose();
    } else {
      instance.lastExitCode = exitCode;
      instance.lastStderrTail = stderrTail;
    }
    instance.worker = null;
    instance.lastError = message;
    _move(instance, PluginState.failed, error: message);
  }

  void _requireCapability(PluginInstance instance, String capability) {
    if (!instance.manifest.capabilities.contains(capability)) {
      throw IpcException.code(IpcErrorCode.capabilityDenied,
          'package "${instance.id}" did not declare the "$capability" capability');
    }
  }

  void _move(PluginInstance instance, PluginState to, {String? error}) {
    final from = instance.transition(to);
    onStateChanged(instance, from, to, error: error);
  }
}
