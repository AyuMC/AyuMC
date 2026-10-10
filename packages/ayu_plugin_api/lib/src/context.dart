import 'dart:async';

import 'package:ayu_ipc/ayu_ipc.dart';

typedef CommandHandler = FutureOr<CommandResult> Function(CommandInvocation call);
typedef EventHandler = FutureOr<void> Function(EventEnvelope event);

/// Operations the context needs from the runner. Kept abstract so the SDK
/// can be exercised in-process by tests.
abstract interface class HostLink {
  Future<Object?> request(String method, [Object? params, Duration? timeout]);
  bool notify(String method, [Object? params]);
  bool get isConnected;
}

/// Everything a plugin may use to talk to the server.
final class PluginContext {
  PluginContext({
    required this.plugin,
    required this.installDirectory,
    required this.dataDirectory,
    required Set<String> capabilities,
    required Map<String, Object?> config,
    required HostLink link,
  })  : capabilities = Set.unmodifiable(capabilities),
        _config = Map.unmodifiable(config),
        _link = link {
    log = PluginLogger._(this);
    commands = PluginCommands._(this);
    events = PluginEvents._(this);
    timers = PluginTimers._();
    host = HostClient._(this);
  }

  final PluginDescriptor plugin;

  /// Directory the package was extracted to. Read-only by convention.
  final String installDirectory;

  /// Directory for the plugin's own persistent files. Survives updates.
  final String dataDirectory;

  /// Capabilities declared in the manifest and granted by the host.
  final Set<String> capabilities;

  final HostLink _link;
  Map<String, Object?> _config;

  late final PluginLogger log;
  late final PluginCommands commands;
  late final PluginEvents events;
  late final PluginTimers timers;
  late final HostClient host;

  /// Configuration snapshot provided by the host at start-up.
  Map<String, Object?> get config => _config;

  bool hasCapability(String capability) => capabilities.contains(capability);

  /// Re-reads the configuration from the host.
  Future<Map<String, Object?>> reloadConfig() async {
    _requireCapability(PluginCapability.config);
    final result = await _link.request(IpcMethod.configGet);
    _config = Map.unmodifiable(JsonFields.object(result, 'config'));
    return _config;
  }

  void _requireCapability(String capability) {
    if (!capabilities.contains(capability)) {
      throw IpcException.code(IpcErrorCode.capabilityDenied,
          'manifest does not declare the "$capability" capability');
    }
  }
}

/// Structured logging routed to the host. Never writes to stdout, which
/// carries the protocol stream.
final class PluginLogger {
  PluginLogger._(this._context);

  final PluginContext _context;

  void debug(String message) => _log(IpcLogLevel.debug, message);
  void info(String message) => _log(IpcLogLevel.info, message);
  void warn(String message) => _log(IpcLogLevel.warn, message);
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(': $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    _log(IpcLogLevel.error, buffer.toString());
  }

  void _log(String level, String message) {
    _context._link.notify(
      IpcMethod.log,
      LogNotification(
        level: level,
        message: message,
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );
  }
}

final class CommandRegistration {
  CommandRegistration._(this._owner, this.name);

  final PluginCommands _owner;
  final String name;

  Future<void> unregister() => _owner.unregister(name);
}

/// Command ownership. Handlers run inside the worker; the host only knows
/// names, aliases and descriptions.
final class PluginCommands {
  PluginCommands._(this._context);

  final PluginContext _context;
  final Map<String, CommandHandler> _handlers = {};

  Iterable<String> get registeredNames => _handlers.keys;

  Future<CommandRegistration> register(
    String name,
    CommandHandler handler, {
    String? description,
    String? usage,
    List<String> aliases = const [],
  }) async {
    _context._requireCapability(PluginCapability.commands);
    if (_handlers.containsKey(name)) {
      throw IpcException.code(IpcErrorCode.conflict, 'command "$name" is already registered by this plugin');
    }
    final spec = CommandSpec(name: name, description: description, usage: usage, aliases: aliases);
    _handlers[name] = handler;
    try {
      await _context._link.request(IpcMethod.commandRegister, spec.toJson());
    } catch (_) {
      _handlers.remove(name);
      rethrow;
    }
    return CommandRegistration._(this, name);
  }

  Future<void> unregister(String name) async {
    if (_handlers.remove(name) == null) return;
    if (!_context._link.isConnected) return;
    await _context._link.request(IpcMethod.commandUnregister, CommandNameSpec(name).toJson());
  }

  /// Runtime-internal dispatch of a host invocation.
  Future<CommandResult> dispatch(CommandInvocation call) async {
    final handler = _handlers[call.name];
    if (handler == null) {
      throw IpcException.code(IpcErrorCode.notFound, 'command "${call.name}" is not handled by this plugin');
    }
    return handler(call);
  }
}

final class EventSubscription {
  EventSubscription._(this._owner, this.type, this._handler);

  final PluginEvents _owner;
  final String type;
  final EventHandler _handler;

  Future<void> cancel() => _owner._cancel(this);
}

/// Event subscriptions. The host delivers only subscribed types; delivery is
/// one-way and may be dropped under backpressure, never blocked.
final class PluginEvents {
  PluginEvents._(this._context);

  final PluginContext _context;
  final Map<String, List<EventSubscription>> _subscriptions = {};

  Future<EventSubscription> subscribe(String type, EventHandler handler) async {
    _context._requireCapability(PluginCapability.events);
    final list = _subscriptions.putIfAbsent(type, () => []);
    final subscription = EventSubscription._(this, type, handler);
    final first = list.isEmpty;
    list.add(subscription);
    if (first) {
      try {
        await _context._link.request(IpcMethod.eventSubscribe, EventSubscriptionSpec(type).toJson());
      } catch (_) {
        list.remove(subscription);
        if (list.isEmpty) _subscriptions.remove(type);
        rethrow;
      }
    }
    return subscription;
  }

  Future<void> _cancel(EventSubscription subscription) async {
    final list = _subscriptions[subscription.type];
    if (list == null || !list.remove(subscription)) return;
    if (list.isNotEmpty) return;
    _subscriptions.remove(subscription.type);
    if (!_context._link.isConnected) return;
    await _context._link.request(
        IpcMethod.eventUnsubscribe, EventSubscriptionSpec(subscription.type).toJson());
  }

  /// Runtime-internal delivery. Handler failures are logged, never fatal.
  Future<void> dispatch(EventEnvelope event) async {
    final handlers = _subscriptions[event.type];
    if (handlers == null) return;
    for (final subscription in List.of(handlers)) {
      try {
        await subscription._handler(event);
      } catch (error, stackTrace) {
        _context.log.error('event handler for "${event.type}" failed', error, stackTrace);
      }
    }
  }
}

/// Timers that are cancelled automatically when the plugin is disabled.
final class PluginTimers {
  PluginTimers._();

  final Set<Timer> _timers = {};

  Timer once(Duration delay, void Function() callback) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      callback();
    });
    _timers.add(timer);
    return timer;
  }

  Timer periodic(Duration interval, void Function(Timer timer) callback) {
    final timer = Timer.periodic(interval, callback);
    _timers.add(timer);
    return timer;
  }

  void cancelAll() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  int get activeCount => _timers.where((t) => t.isActive).length;
}

/// Generic request path for host methods that have no dedicated wrapper.
final class HostClient {
  HostClient._(this._context);

  final PluginContext _context;

  Future<Object?> request(String method, [Object? params, Duration? timeout]) =>
      _context._link.request(method, params, timeout);
}
