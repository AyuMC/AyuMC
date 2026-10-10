import 'package:pub_semver/pub_semver.dart';

import 'plugin_state.dart';

/// Immutable view of a plugin for UIs and tests.
final class PluginSnapshot {
  const PluginSnapshot({
    required this.id,
    required this.name,
    required this.version,
    required this.state,
    required this.enabled,
    required this.installDirectory,
    required this.dataDirectory,
    required this.capabilities,
    required this.dependencies,
    required this.pid,
    required this.restartCount,
    required this.droppedEvents,
    required this.lastError,
    required this.lastExitCode,
    required this.stderrTail,
  });

  final String id;
  final String name;
  final Version version;
  final PluginState state;

  /// Desired state persisted in the store.
  final bool enabled;
  final String installDirectory;
  final String dataDirectory;
  final Set<String> capabilities;
  final List<String> dependencies;
  final int? pid;
  final int restartCount;

  /// Events dropped for this plugin because its channel was congested.
  final int droppedEvents;
  final String? lastError;
  final int? lastExitCode;

  /// Last stderr output of the most recent worker, for diagnostics.
  final String stderrTail;

  @override
  String toString() => '$id $version [${state.name}]${lastError == null ? '' : ' - $lastError'}';
}
