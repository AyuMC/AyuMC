import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';

import 'plugin_snapshot.dart';
import 'plugin_state.dart';
import 'worker_process.dart';

/// Mutable host-side record of one installed plugin version. Only
/// `PluginHost` mutates it, always under the plugin's operation lock.
final class PluginInstance {
  PluginInstance({
    required this.manifest,
    required this.installDirectory,
    required this.dataDirectory,
    required PluginState initialState,
  }) : _state = initialState;

  final PluginManifest manifest;
  final Directory installDirectory;
  final Directory dataDirectory;

  PluginState _state;
  WorkerProcess? worker;
  String? lastError;
  int? lastExitCode;
  String lastStderrTail = '';
  int droppedEvents = 0;
  final List<DateTime> restartTimes = [];

  String get id => manifest.id;
  Version get version => manifest.version;
  PluginState get state => _state;
  bool get isEventPack => manifest.isEventPack;

  /// Whether this pack's contracts are currently registered as available.
  bool providerRegistered = false;

  /// Applies a validated transition and returns the previous state.
  PluginState transition(PluginState to) {
    PluginStateMachine.check(id, _state, to);
    final from = _state;
    _state = to;
    return from;
  }

  /// Records restarts and tells whether another one fits the budget.
  bool consumeRestartBudget({
    required int maxRestarts,
    required Duration window,
    required DateTime now,
  }) {
    restartTimes.removeWhere((t) => now.difference(t) > window);
    if (restartTimes.length >= maxRestarts) return false;
    restartTimes.add(now);
    return true;
  }

  void recordWorkerFailure(WorkerProcess process, String error) {
    lastError = error;
    lastExitCode = process.exitCode;
    lastStderrTail = process.stderrTail;
  }

  PluginSnapshot snapshot({required bool enabled}) => PluginSnapshot(
    id: id,
    name: manifest.name,
    version: version,
    packageType: manifest.packageType,
    provides: [
      for (final c in manifest.provides)
        '${c.id} ${c.version} (${c.delivery.mode.name})',
    ],
    requiredContracts: [
      for (final e in manifest.requiredEvents) '${e.id} ${e.version}',
    ],
    optionalContracts: [
      for (final e in manifest.optionalEvents) '${e.id} ${e.version}',
    ],
    state: _state,
    enabled: enabled,
    installDirectory: installDirectory.path,
    dataDirectory: dataDirectory.path,
    capabilities: manifest.capabilities,
    dependencies: [
      for (final d in manifest.dependencies)
        '${d.id} ${d.version}${d.optional ? ' (optional)' : ''}',
    ],
    pid: worker?.hasExited == false ? worker!.pid : null,
    restartCount: restartTimes.length,
    droppedEvents: droppedEvents,
    lastError: lastError,
    lastExitCode: lastExitCode,
    stderrTail: lastStderrTail,
  );
}
