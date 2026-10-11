import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';

import 'plugin_state.dart';

/// Immutable view of an installed package for UIs and tests.
final class PluginSnapshot {
  const PluginSnapshot({
    required this.id,
    required this.name,
    required this.version,
    required this.packageType,
    required this.provides,
    required this.requiredContracts,
    required this.optionalContracts,
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
    this.configState = '',
    this.configRevision = 0,
    this.configSchema,
    this.configError,
  });

  final String id;
  final String name;
  final Version version;
  final PackageType packageType;

  /// Contracts an event pack provides (`id version (mode)`).
  final List<String> provides;
  final List<String> requiredContracts;
  final List<String> optionalContracts;
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

  /// Last reported AyuConfig reload state, empty when the plugin has not reported one.
  final String configState;
  final int configRevision;
  final int? configSchema;
  final String? configError;

  bool get isEventPack => packageType == PackageType.eventPack;

  @override
  String toString() =>
      '$id $version [${state.name}]${isEventPack ? ' (event pack)' : ''}${lastError == null ? '' : ' - $lastError'}';
}
