import 'plugin_state.dart';

sealed class PluginHostEvent {
  const PluginHostEvent(this.pluginId);

  final String pluginId;
}

final class PluginStateChanged extends PluginHostEvent {
  const PluginStateChanged(super.pluginId, this.from, this.to, {this.error});

  final PluginState from;
  final PluginState to;
  final String? error;

  @override
  String toString() => '$pluginId: ${from.name} -> ${to.name}${error == null ? '' : ' ($error)'}';
}

/// A structured log line sent by a plugin.
final class PluginLogged extends PluginHostEvent {
  const PluginLogged(super.pluginId, this.level, this.message, this.timestamp);

  final String level;
  final String message;
  final DateTime timestamp;
}
