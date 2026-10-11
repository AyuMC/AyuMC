import 'dart:async';

import 'context.dart';
import 'listeners.dart';

/// Base class of every AyuMC plugin.
///
/// Lifecycle: the runtime attaches the [context], then awaits [onEnable].
/// Only after it completes does the host mark the plugin active and route
/// commands and events to it. On shutdown the host awaits [onDisable] for a
/// bounded grace period, then the process exits; anything still running is
/// terminated with it.
abstract class AyuPlugin {
  PluginContext? _context;

  /// Handlers subscribed by the runner. Keep the listener instances in fields.
  List<Listener> get listeners => const [];

  /// Console commands registered by the runner. Not Minecraft chat commands.
  List<PluginCommand> get commands => const [];

  /// Called once the host context exists. The default plugin is already that object.
  AyuPlugin materialize(PluginContext context) => this;

  /// Access to the host. Available from [onEnable] until the process ends.
  PluginContext get context {
    final context = _context;
    if (context == null) {
      throw StateError('context is available from onEnable onwards');
    }
    return context;
  }

  /// Register commands, subscribe to events, load state. Throwing here
  /// fails activation; the host reports the error and stops the worker.
  FutureOr<void> onEnable() {}

  /// Release what [onEnable] acquired. Registrations held through the
  /// context are removed by the host regardless of what happens here.
  FutureOr<void> onDisable() {}
}

/// Runtime-internal: binds the context before `onEnable`.
void attachContext(AyuPlugin plugin, PluginContext context) {
  plugin._context = context;
}
