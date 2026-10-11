import 'dart:async';

import 'package:ayu_ipc/ayu_ipc.dart';

typedef CommandHandler = FutureOr<CommandResult> Function(CommandInvocation call);
typedef EventHandler = FutureOr<void> Function(EventEnvelope event);
typedef DecisionHandler = FutureOr<Decision> Function(DecisionRequest request);
typedef AvailabilityHandler = void Function(ContractAvailability change);
typedef GapHandler = void Function(DeliveryGap gap);
typedef PrimitiveHandler = FutureOr<void> Function(PrimitiveEnvelope primitive);
typedef PrimitiveDecisionHandler = FutureOr<PrimitiveDecision> Function(DecisionRequest request);

/// Verdict of a plugin on a decision contract.
final class Decision {
  const Decision._(this.verdict, this.reason);

  const Decision.allow() : this._(Verdict.allow, null);

  const Decision.deny([String? reason]) : this._(Verdict.deny, reason);

  final String verdict;
  final String? reason;

  DecisionResponse toResponse() => DecisionResponse.verdict(verdict, reason: reason);
}

/// Answer of an event pack to a decision primitive: translate it into a
/// contract event for the consumers to judge, or settle it directly.
final class PrimitiveDecision {
  const PrimitiveDecision._(this._response);

  /// Put [data] to the consumers of [contract]; their verdicts decide.
  PrimitiveDecision.translate(String contract, Map<String, Object?> data)
      : this._(DecisionResponse.translate(contract, data));

  /// Let the operation proceed without consulting consumers.
  const PrimitiveDecision.allow() : this._(const DecisionResponse.verdict(Verdict.allow));

  /// Veto the operation without consulting consumers.
  PrimitiveDecision.deny([String? reason]) : this._(DecisionResponse.verdict(Verdict.deny, reason: reason));

  final DecisionResponse _response;

  DecisionResponse toResponse() => _response;
}

/// Operations the context needs from the runner. Kept abstract so the SDK
/// can be exercised in-process by tests.
abstract interface class HostLink {
  Future<Object?> request(String method, [Object? params, Duration? timeout]);
  bool notify(String method, [Object? params]);
  bool get isConnected;
}

/// Everything a package may use to talk to the server.
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
    primitives = PrimitiveObservations._(this);
    timers = PluginTimers._();
    host = HostClient._(this);
  }

  final PluginDescriptor plugin;

  /// Directory the package was extracted to. Read-only by convention.
  final String installDirectory;

  /// Directory for the package's own persistent files. Survives updates.
  final String dataDirectory;

  /// Capabilities declared in the manifest and granted by the host.
  final Set<String> capabilities;

  final HostLink _link;
  Map<String, Object?> _config;

  late final PluginLogger log;
  late final PluginCommands commands;

  /// Contract events: subscribe (plugins), publish (event packs).
  late final PluginEvents events;

  /// Internal primitives: event packs only.
  late final PrimitiveObservations primitives;
  late final PluginTimers timers;
  late final HostClient host;

  /// Configuration snapshot provided by the host at start-up.
  Map<String, Object?> get config => _config;

  bool hasCapability(String capability) => capabilities.contains(capability);

  /// Tells the manager that a configuration file was applied or rejected.
  /// This does not restart the worker.
  void reportConfigStatus({required String state, required int revision, String? error, int? schemaVersion}) {
    _link.notify(IpcMethod.configStatus, {
      'state': state,
      'revision': revision,
      if (schemaVersion != null) 'schema': schemaVersion,
      if (error != null && error.isNotEmpty) 'error': error,
    });
  }

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
      LogNotification(level: level, message: message, timestampMillis: DateTime.now().millisecondsSinceEpoch).toJson(),
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
  EventSubscription._(this._owner, this.type, this._handler, this._decider);

  final PluginEvents _owner;
  final String type;
  final EventHandler? _handler;
  final DecisionHandler? _decider;

  Future<void> cancel() => _owner._cancel(this);
}

/// Contract events.
///
/// Plugins subscribe to contracts declared in their manifest; delivery is
/// one-way for observational contracts and request/response for decision
/// contracts. Event packs publish contract events they declared.
final class PluginEvents {
  PluginEvents._(this._context);

  final PluginContext _context;
  final Map<String, List<EventSubscription>> _subscriptions = {};
  final List<AvailabilityHandler> _availabilityHandlers = [];
  final List<GapHandler> _gapHandlers = [];
  final List<PublishedEvent> _publishQueue = [];
  bool _flushScheduled = false;

  /// Receives events of an observational contract.
  Future<EventSubscription> subscribe(String type, EventHandler handler) =>
      _subscribe(type, handler: handler);

  /// Judges events of a decision contract. The host waits for the verdict
  /// within the contract's budget; a late verdict is ignored and the
  /// contract's timeout policy applies.
  Future<EventSubscription> decide(String type, DecisionHandler handler) =>
      _subscribe(type, decider: handler);

  /// Notified when an optional contract becomes available or disappears.
  void onAvailabilityChanged(AvailabilityHandler handler) => _availabilityHandlers.add(handler);

  /// Notified when the host had to drop events for this consumer.
  void onDeliveryGap(GapHandler handler) => _gapHandlers.add(handler);

  /// Event packs: publish a contract event. Several publishes within one
  /// event-loop turn travel in a single frame.
  void publish(String contract, Map<String, Object?> data) {
    _context._requireCapability(PluginCapability.publish);
    _publishQueue.add(PublishedEvent(contract: contract, data: data, timestampMillis: DateTime.now().millisecondsSinceEpoch));
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flushPublishQueue);
  }

  void _flushPublishQueue() {
    _flushScheduled = false;
    if (_publishQueue.isEmpty) return;
    final items = List.of(_publishQueue);
    _publishQueue.clear();
    final sent = items.length == 1
        ? _context._link.notify(IpcMethod.eventPublish, items.single.toJson())
        : _context._link.notify(IpcMethod.eventPublishBatch, PublishedEventBatch(items).toJson());
    if (!sent) _context.log.warn('${items.length} published event(s) dropped: channel congested or closed');
  }

  Future<EventSubscription> _subscribe(String type, {EventHandler? handler, DecisionHandler? decider}) async {
    _context._requireCapability(PluginCapability.events);
    final list = _subscriptions.putIfAbsent(type, () => []);
    final subscription = EventSubscription._(this, type, handler, decider);
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
    await _context._link.request(IpcMethod.eventUnsubscribe, EventSubscriptionSpec(subscription.type).toJson());
  }

  /// Runtime-internal delivery. Handler failures are logged, never fatal.
  Future<void> dispatch(EventEnvelope event) async {
    final handlers = _subscriptions[event.type];
    if (handlers == null) return;
    for (final subscription in List.of(handlers)) {
      final handler = subscription._handler;
      if (handler == null) continue;
      try {
        await handler(event);
      } catch (error, stackTrace) {
        _context.log.error('event handler for "${event.type}" failed', error, stackTrace);
      }
    }
  }

  /// Runtime-internal: collects verdicts; any deny wins. A handler error
  /// counts as deny so a broken plugin fails closed on its own share.
  Future<Decision> judge(DecisionRequest request) async {
    final handlers = _subscriptions[request.id];
    if (handlers == null) return const Decision.allow();
    for (final subscription in List.of(handlers)) {
      final decider = subscription._decider;
      if (decider == null) continue;
      try {
        final decision = await decider(request);
        if (decision.verdict == Verdict.deny) return decision;
      } catch (error, stackTrace) {
        _context.log.error('decision handler for "${request.id}" failed', error, stackTrace);
        return Decision.deny('handler failed: $error');
      }
    }
    return const Decision.allow();
  }

  void notifyAvailability(ContractAvailability change) {
    for (final handler in List.of(_availabilityHandlers)) {
      try {
        handler(change);
      } catch (error, stackTrace) {
        _context.log.error('availability handler failed', error, stackTrace);
      }
    }
  }

  void notifyGap(DeliveryGap gap) {
    for (final handler in List.of(_gapHandlers)) {
      try {
        handler(gap);
      } catch (error, stackTrace) {
        _context.log.error('gap handler failed', error, stackTrace);
      }
    }
  }
}

final class PrimitiveSubscription {
  PrimitiveSubscription._(this._owner, this.id);

  final PrimitiveObservations _owner;
  final String id;

  Future<void> cancel() => _owner._cancel(this);
}

/// Internal primitives (event packs only). The host forwards a primitive
/// only while a contract fed by it has consumers.
final class PrimitiveObservations {
  PrimitiveObservations._(this._context);

  final PluginContext _context;
  final Map<String, List<(PrimitiveSubscription, PrimitiveHandler)>> _observers = {};
  final Map<String, PrimitiveDecisionHandler> _deciders = {};

  /// Observes an observational primitive.
  Future<PrimitiveSubscription> observe(String id, PrimitiveHandler handler) async {
    _context._requireCapability(PluginCapability.observe);
    final list = _observers.putIfAbsent(id, () => []);
    final subscription = PrimitiveSubscription._(this, id);
    final first = list.isEmpty && !_deciders.containsKey(id);
    list.add((subscription, handler));
    if (first) {
      try {
        await _context._link.request(IpcMethod.observeSubscribe, PrimitiveSubscriptionSpec(id).toJson());
      } catch (_) {
        list.removeWhere((e) => identical(e.$1, subscription));
        if (list.isEmpty) _observers.remove(id);
        rethrow;
      }
    }
    return subscription;
  }

  /// Translates (or settles) a decision primitive. One handler per
  /// primitive.
  Future<void> decide(String id, PrimitiveDecisionHandler handler) async {
    _context._requireCapability(PluginCapability.observe);
    if (_deciders.containsKey(id)) {
      throw IpcException.code(IpcErrorCode.conflict, 'a decision handler for "$id" is already registered');
    }
    final first = !_observers.containsKey(id);
    _deciders[id] = handler;
    if (first) {
      try {
        await _context._link.request(IpcMethod.observeSubscribe, PrimitiveSubscriptionSpec(id).toJson());
      } catch (_) {
        _deciders.remove(id);
        rethrow;
      }
    }
  }

  Future<void> _cancel(PrimitiveSubscription subscription) async {
    final list = _observers[subscription.id];
    if (list == null) return;
    list.removeWhere((e) => identical(e.$1, subscription));
    if (list.isNotEmpty) return;
    _observers.remove(subscription.id);
    if (_deciders.containsKey(subscription.id) || !_context._link.isConnected) return;
    await _context._link.request(IpcMethod.observeUnsubscribe, PrimitiveSubscriptionSpec(subscription.id).toJson());
  }

  /// Runtime-internal delivery.
  Future<void> dispatch(PrimitiveEnvelope primitive) async {
    final observers = _observers[primitive.id];
    if (observers == null) return;
    for (final (_, handler) in List.of(observers)) {
      try {
        await handler(primitive);
      } catch (error, stackTrace) {
        _context.log.error('primitive handler for "${primitive.id}" failed', error, stackTrace);
      }
    }
  }

  /// Runtime-internal: a failing or missing handler lets the host apply the
  /// contract's timeout policy by returning no translation.
  Future<PrimitiveDecision> judge(DecisionRequest request) async {
    final handler = _deciders[request.id];
    if (handler == null) return const PrimitiveDecision.allow();
    return handler(request);
  }
}

/// Timers that are cancelled automatically when the package is disabled.
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
