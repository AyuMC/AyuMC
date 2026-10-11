import 'dart:async';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';

import 'context.dart';
import 'plugin.dart';

/// Version of this SDK, reported to the host during the handshake.
const sdkVersion = '1.0.0';

/// Process exit codes used by the runner.
abstract final class PluginExitCode {
  static const ok = 0;

  /// The host connection ended without a shutdown request.
  static const hostLost = 2;

  /// Handshake or protocol failure.
  static const protocol = 70;
}

final class PluginRunnerOptions {
  const PluginRunnerOptions({
    this.channel = const ChannelOptions(),
    this.helloTimeout = const Duration(seconds: 10),
    this.initWaitTimeout = const Duration(seconds: 60),
    this.hostLostDisableTimeout = const Duration(seconds: 2),
    this.input,
    this.output,
    this.exitProcess = true,
  });

  final ChannelOptions channel;

  /// How long to wait for the host to answer `hello`.
  final Duration helloTimeout;

  /// How long to wait for the host's `init` after a successful hello.
  final Duration initWaitTimeout;

  /// Grace given to `onDisable` when the host vanished without asking.
  final Duration hostLostDisableTimeout;

  /// Overrides for embedding the runner in-process (tests). Default: stdio.
  final Stream<List<int>>? input;
  final IOSink? output;

  /// Call `exit()` when the runner finishes. Disable only when embedding.
  final bool exitProcess;
}

/// Builds the plugin after the host context exists, then runs it.
abstract final class Ayu {
  static Future<int> run(
    AyuPlugin Function(PluginContext context) create, {
    PluginRunnerOptions options = const PluginRunnerOptions(),
  }) {
    return runPlugin(_FactoryPlugin(create), options: options);
  }
}

final class _FactoryPlugin extends AyuPlugin {
  _FactoryPlugin(this._create);

  final AyuPlugin Function(PluginContext context) _create;
  AyuPlugin? _child;

  @override
  AyuPlugin materialize(PluginContext context) => _child ??= _create(context);
}

/// Runs [plugin] until the host asks it to stop. Returns the exit code when
/// [PluginRunnerOptions.exitProcess] is false; otherwise exits the process.
Future<int> runPlugin(
  AyuPlugin plugin, {
  PluginRunnerOptions options = const PluginRunnerOptions(),
}) async {
  final runner = _PluginRunner(plugin, options);
  final code =
      await runZonedGuarded(
        runner.run,
        runner.onUncaughtError,
        zoneSpecification: ZoneSpecification(print: runner.onPrint),
      ) ??
      PluginExitCode.protocol;
  if (options.exitProcess) exit(code);
  return code;
}

final class _PluginRunner implements HostLink {
  _PluginRunner(this._plugin, this._options);

  final AyuPlugin _plugin;
  final PluginRunnerOptions _options;
  late final FrameChannel _channel;
  final Completer<int> _exit = Completer<int>();
  final Completer<void> _initReceived = Completer<void>();
  PluginContext? _context;
  AyuPlugin? _active;
  final List<EventSubscription> _ownedEvents = [];
  final List<CommandRegistration> _ownedCommands = [];
  bool _shuttingDown = false;

  @override
  bool get isConnected => _channel.isOpen;

  @override
  Future<Object?> request(String method, [Object? params, Duration? timeout]) =>
      _channel.request(method, params, timeout);

  @override
  bool notify(String method, [Object? params]) =>
      _channel.notify(method, params);

  Future<int> run() async {
    _channel =
        FrameChannel(
            input: _options.input ?? stdin,
            output: IoFrameSink(_options.output ?? stdout),
            options: _options.channel,
            debugName: 'plugin',
          )
          ..onRequest = _handleRequest
          ..onNotification = _handleNotification
          ..onUnhandledError = onUncaughtError;
    unawaited(_channel.done.then((_) => _onChannelClosed()));

    try {
      final response = HelloResponse.fromJson(
        await _channel.request(
          IpcMethod.hello,
          HelloRequest(
            protocolVersions: IpcProtocol.supportedVersions,
            sdkVersion: sdkVersion,
            dartVersion: Platform.version,
            pid: pid,
          ).toJson(),
          _options.helloTimeout,
        ),
      );
      if (!IpcProtocol.supportedVersions.contains(response.protocolVersion)) {
        return _fail(
          'host selected unsupported protocol version ${response.protocolVersion}',
        );
      }
    } on IpcException catch (e) {
      return _fail('handshake failed: $e');
    }

    try {
      await _initReceived.future.timeout(_options.initWaitTimeout);
    } on TimeoutException {
      return _fail(
        'host did not send init within ${_options.initWaitTimeout.inSeconds}s',
      );
    } on IpcException {
      // The channel closed before init; _onChannelClosed already reported it.
      return PluginExitCode.hostLost;
    }
    return _exit.future;
  }

  int _fail(String message) {
    _shuttingDown = true;
    stderr.writeln('[ayu_plugin_api] $message');
    unawaited(_channel.close());
    return PluginExitCode.protocol;
  }

  Future<Object?> _handleRequest(String method, Object? params) async {
    switch (method) {
      case IpcMethod.init:
        return _init(InitRequest.fromJson(params));
      case IpcMethod.shutdown:
        return _shutdown(ShutdownRequest.fromJson(params));
      case IpcMethod.ping:
        return const <String, Object?>{};
      case IpcMethod.eventDecide:
        final decision = await _requireContext().events.judge(
          DecisionRequest.fromJson(params),
        );
        return decision.toResponse().toJson();
      case IpcMethod.primitiveDecide:
        final decision = await _requireContext().primitives.judge(
          DecisionRequest.fromJson(params),
        );
        return decision.toResponse().toJson();
      case IpcMethod.commandExecute:
        final context = _requireContext();
        final invocation = CommandInvocation.fromJson(params);
        try {
          final result = await context.commands.dispatch(invocation);
          return result.toJson();
        } on IpcException {
          rethrow;
        } catch (error, stackTrace) {
          context.log.error(
            'command "${invocation.name}" failed',
            error,
            stackTrace,
          );
          throw IpcException.code(
            IpcErrorCode.internal,
            'command "${invocation.name}" threw: $error',
          );
        }
      default:
        throw IpcException.code(
          IpcErrorCode.methodNotFound,
          'worker does not implement $method',
        );
    }
  }

  void _handleNotification(String method, Object? params) {
    final context = _context;
    if (context == null) return;
    switch (method) {
      case IpcMethod.event:
        unawaited(context.events.dispatch(EventEnvelope.fromJson(params)));
      case IpcMethod.eventBatch:
        unawaited(
          _dispatchSequentially(
            EventBatch.fromJson(params).items,
            context.events.dispatch,
          ),
        );
      case IpcMethod.primitive:
        unawaited(
          context.primitives.dispatch(PrimitiveEnvelope.fromJson(params)),
        );
      case IpcMethod.primitiveBatch:
        unawaited(
          _dispatchSequentially(
            PrimitiveBatch.fromJson(params).items,
            context.primitives.dispatch,
          ),
        );
      case IpcMethod.contractChanged:
        context.events.notifyAvailability(
          ContractAvailability.fromJson(params),
        );
      case IpcMethod.deliveryGap:
        context.events.notifyGap(DeliveryGap.fromJson(params));
    }
  }

  /// Items of one batch keep their order relative to each other.
  static Future<void> _dispatchSequentially<T>(
    List<T> items,
    Future<void> Function(T) dispatch,
  ) async {
    for (final item in items) {
      await dispatch(item);
    }
  }

  Future<Object?> _init(InitRequest init) async {
    if (_context != null) {
      throw IpcException.code(
        IpcErrorCode.conflict,
        'plugin already initialised',
      );
    }
    final context = PluginContext(
      plugin: init.plugin,
      installDirectory: init.installDirectory,
      dataDirectory: init.dataDirectory,
      capabilities: init.capabilities.toSet(),
      config: init.config,
      link: this,
    );
    _context = context;
    attachContext(_plugin, context);
    final active = _plugin.materialize(context);
    _active = active;
    if (!identical(active, _plugin)) attachContext(active, context);
    if (!_initReceived.isCompleted) _initReceived.complete();
    try {
      await _bind(active);
      await active.onEnable();
    } catch (error, stackTrace) {
      try {
        await Future<void>.sync(
          () => _active?.onDisable(),
        ).timeout(const Duration(seconds: 2));
      } catch (disableError, disableStack) {
        context.log.error(
          'onDisable after a failed onEnable',
          disableError,
          disableStack,
        );
      }
      await _releaseOwned();
      context.timers.cancelAll();
      throw IpcException.code(
        IpcErrorCode.internal,
        'onEnable failed: $error',
        data: {'stackTrace': '$stackTrace'},
      );
    }
    return const <String, Object?>{};
  }

  Future<void> _bind(AyuPlugin plugin) async {
    final context = _context;
    if (context == null) return;
    for (final listener in plugin.listeners) {
      for (final handler in listener.handlers) {
        _ownedEvents.add(
          await context.events.subscribe(handler.contractId, (event) {
            handler.dispatch(event.data);
          }),
        );
      }
    }
    for (final command in plugin.commands) {
      _ownedCommands.add(
        await context.commands.register(
          command.name,
          command.execute,
          description: command.description,
          usage: command.usage,
          aliases: command.aliases,
        ),
      );
    }
  }

  Future<void> _releaseOwned() async {
    final events = List.of(_ownedEvents);
    final commands = List.of(_ownedCommands);
    _ownedEvents.clear();
    _ownedCommands.clear();
    for (final subscription in events) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        _context?.log.error('event cleanup failed', error, stackTrace);
      }
    }
    for (final command in commands) {
      try {
        await command.unregister();
      } catch (error, stackTrace) {
        _context?.log.error('command cleanup failed', error, stackTrace);
      }
    }
  }

  Future<Object?> _shutdown(ShutdownRequest request) async {
    if (_shuttingDown) return const <String, Object?>{};
    _shuttingDown = true;
    await _disable(Duration(milliseconds: request.graceMillis));
    // Respond, then let the response leave the pipe before exiting.
    scheduleMicrotask(() async {
      await _channel.close();
      if (!_exit.isCompleted) _exit.complete(PluginExitCode.ok);
    });
    return const <String, Object?>{};
  }

  Future<void> _disable(Duration grace) async {
    final context = _context;
    if (context == null) return;
    final active = _active ?? _plugin;
    try {
      await Future.sync(active.onDisable).timeout(grace);
    } on TimeoutException {
      context.log.error(
        'onDisable exceeded its ${grace.inMilliseconds} ms grace period',
      );
    } catch (error, stackTrace) {
      context.log.error('onDisable failed', error, stackTrace);
    } finally {
      await _releaseOwned();
      context.timers.cancelAll();
    }
  }

  Future<void> _onChannelClosed() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    if (!_initReceived.isCompleted) {
      _initReceived.completeError(
        IpcException.code(IpcErrorCode.closed, 'host connection closed'),
      );
    }
    stderr.writeln(
      '[ayu_plugin_api] host connection closed (${_channel.closeReason}); stopping',
    );
    await _disable(_options.hostLostDisableTimeout);
    if (!_exit.isCompleted) _exit.complete(PluginExitCode.hostLost);
  }

  PluginContext _requireContext() {
    final context = _context;
    if (context == null) {
      throw IpcException.code(
        IpcErrorCode.unavailable,
        'plugin is not initialised',
      );
    }
    return context;
  }

  void onUncaughtError(Object error, StackTrace stackTrace) {
    final context = _context;
    if (context != null && _channel.isOpen) {
      context.log.error('uncaught error', error, stackTrace);
    } else {
      stderr.writeln('[ayu_plugin_api] uncaught error: $error\n$stackTrace');
    }
  }

  /// `print()` must never reach stdout: it would corrupt the protocol.
  void onPrint(Zone self, ZoneDelegate parent, Zone zone, String line) {
    final context = _context;
    if (context != null && _channel.isOpen) {
      context.log.info(line);
    } else {
      stderr.writeln(line);
    }
  }
}
