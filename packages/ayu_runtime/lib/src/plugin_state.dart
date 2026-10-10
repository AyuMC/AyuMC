/// Lifecycle states of an installed plugin.
enum PluginState {
  /// Found in the store at start-up; nothing verified yet.
  discovered,

  /// Package being inspected and checked for compatibility.
  validating,

  /// Extracted and verified on disk; no worker.
  staged,

  /// Worker process launched; handshake or `onEnable` in progress.
  starting,

  /// `onEnable` completed; commands and events are routed.
  active,

  /// Registrations removed; worker asked to exit or being killed.
  stopping,

  /// No worker. Can be enabled.
  disabled,

  /// Start, stop or update failed. No worker is routed to. Can be retried.
  failed,

  /// Worker exited while active. No worker. Restart may be pending.
  crashed,

  /// Enabled, but a required contract lost its provider. No worker. Starts
  /// again automatically when the contract becomes available.
  suspended;

  bool get hasWorker => this == starting || this == active || this == stopping;
}

final class InvalidStateTransition implements Exception {
  const InvalidStateTransition(this.pluginId, this.from, this.to);

  final String pluginId;
  final PluginState from;
  final PluginState to;

  @override
  String toString() => 'plugin "$pluginId": cannot go from ${from.name} to ${to.name}';
}

/// Validated transition table. Any transition not listed is a bug.
abstract final class PluginStateMachine {
  static const Map<PluginState, Set<PluginState>> allowed = {
    PluginState.discovered: {PluginState.validating, PluginState.disabled, PluginState.failed},
    PluginState.validating: {PluginState.staged, PluginState.failed},
    PluginState.staged: {PluginState.starting, PluginState.disabled, PluginState.suspended},
    PluginState.starting: {PluginState.active, PluginState.failed},
    PluginState.active: {PluginState.stopping, PluginState.crashed},
    PluginState.stopping: {PluginState.disabled, PluginState.suspended, PluginState.failed},
    PluginState.disabled: {PluginState.starting, PluginState.validating, PluginState.suspended},
    PluginState.failed: {PluginState.starting, PluginState.disabled, PluginState.validating, PluginState.suspended},
    PluginState.crashed: {PluginState.starting, PluginState.disabled, PluginState.validating, PluginState.suspended},
    PluginState.suspended: {PluginState.starting, PluginState.disabled, PluginState.validating},
  };

  static bool canTransition(PluginState from, PluginState to) => allowed[from]!.contains(to);

  static void check(String pluginId, PluginState from, PluginState to) {
    if (!canTransition(from, to)) throw InvalidStateTransition(pluginId, from, to);
  }
}
