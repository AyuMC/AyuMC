import 'dart:async';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_plugin_api/ayu_plugin_api.dart';
import 'package:test/test.dart';

/// FrameSink over a StreamController, used as the fake host's output.
final class _ControllerSink implements FrameSink {
  _ControllerSink(this.controller);

  final StreamController<List<int>> controller;

  @override
  void add(List<int> bytes) => controller.add(bytes);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() => controller.close();
}

final class _PingListener extends Listener {
  int hits = 0;

  @override
  List<BoundHandler> get handlers => [
    on(
      EventContract<String>(
        id: 'demo.ping',
        version: '1.0.0',
        decode: (data) => '${data['n']}',
      ),
      (String _) => hits++,
    ),
  ];
}

final class _ListedPlugin extends AyuPlugin {
  final listener = _PingListener();
  int listenerReads = 0;

  @override
  List<Listener> get listeners {
    listenerReads++;
    return [listener];
  }
}

final class _Probe extends AyuPlugin {
  final List<String> calls = [];
  final List<EventEnvelope> events = [];
  bool failEnable = false;
  Duration disableDelay = Duration.zero;

  @override
  Future<void> onEnable() async {
    calls.add('enable');
    if (failEnable) throw StateError('cannot enable');
    await context.commands.register(
      'hello',
      (call) async {
        return CommandResult.ok(
          'Hello ${call.args.isEmpty ? call.sender : call.args.first} (${context.config['greeting']})',
        );
      },
      description: 'Greets',
      aliases: ['hi'],
    );
    await context.events.subscribe('player.join', (event) {
      events.add(event);
    });
    context.timers.periodic(const Duration(hours: 1), (_) {});
    print('printed line');
  }

  @override
  Future<void> onDisable() async {
    calls.add('disable');
    if (disableDelay > Duration.zero) await Future<void>.delayed(disableDelay);
  }
}

/// Drives the runner in-process through a loopback and records what the
/// worker asked for.
final class _FakeHost {
  _FakeHost() {
    final hostToPlugin = StreamController<List<int>>();
    final pluginToHost = StreamController<List<int>>();
    channel =
        FrameChannel(
            input: pluginToHost.stream,
            output: _ControllerSink(hostToPlugin),
            debugName: 'host',
          )
          ..onRequest = _onRequest
          ..onNotification = (method, params) {
            if (method == IpcMethod.log) {
              logs.add(LogNotification.fromJson(params));
            }
          };
    pluginOptions = PluginRunnerOptions(
      input: hostToPlugin.stream,
      output: IOSink(pluginToHost.sink),
      exitProcess: false,
      helloTimeout: const Duration(seconds: 5),
      initWaitTimeout: const Duration(seconds: 5),
    );
  }

  late final FrameChannel channel;
  late final PluginRunnerOptions pluginOptions;
  final Completer<HelloRequest> hello = Completer<HelloRequest>();
  final List<CommandSpec> registered = [];
  final List<String> unregistered = [];
  final List<String> subscribed = [];
  final List<String> unsubscribed = [];
  final List<LogNotification> logs = [];

  Future<Object?> _onRequest(String method, Object? params) async {
    switch (method) {
      case IpcMethod.hello:
        final request = HelloRequest.fromJson(params);
        hello.complete(request);
        return HelloResponse(
          protocolVersion: IpcProtocol.negotiate(request.protocolVersions)!,
          hostVersion: 'test',
          apiVersion: IpcProtocol.apiVersion,
          maxFrameBytes: channel.options.maxFrameBytes,
        ).toJson();
      case IpcMethod.commandRegister:
        registered.add(CommandSpec.fromJson(params));
        return null;
      case IpcMethod.commandUnregister:
        unregistered.add(CommandNameSpec.fromJson(params).name);
        return null;
      case IpcMethod.eventSubscribe:
        subscribed.add(EventSubscriptionSpec.fromJson(params).type);
        return null;
      case IpcMethod.eventUnsubscribe:
        unsubscribed.add(EventSubscriptionSpec.fromJson(params).type);
        return null;
      case IpcMethod.configGet:
        return {'greeting': 'reloaded'};
      default:
        throw IpcException.code(IpcErrorCode.methodNotFound, method);
    }
  }

  Future<Object?> init({
    List<String> capabilities = const ['commands', 'events', 'config'],
  }) => channel.request(
    IpcMethod.init,
    InitRequest(
      plugin: const PluginDescriptor(
        id: 'probe',
        name: 'Probe',
        version: '1.0.0',
      ),
      installDirectory: '/install',
      dataDirectory: '/data',
      capabilities: capabilities,
      config: const {'greeting': 'hi'},
    ).toJson(),
  );

  Future<Object?> shutdown({int graceMillis = 1000}) => channel.request(
    IpcMethod.shutdown,
    ShutdownRequest(reason: 'test', graceMillis: graceMillis).toJson(),
  );
}

void main() {
  test('full lifecycle: hello, init, command, event, shutdown', () async {
    final host = _FakeHost();
    final plugin = _Probe();
    final exitCode = runPlugin(plugin, options: host.pluginOptions);

    final hello = await host.hello.future;
    expect(hello.protocolVersions, contains(IpcProtocol.version));
    expect(hello.pid, pid);

    await host.init();
    expect(plugin.calls, ['enable']);
    expect(host.registered.single.name, 'hello');
    expect(host.registered.single.aliases, ['hi']);
    expect(host.subscribed, ['player.join']);
    expect(host.logs.map((l) => l.message), contains('printed line'));

    final result = CommandResult.fromJson(
      await host.channel.request(
        IpcMethod.commandExecute,
        CommandInvocation(
          name: 'hello',
          args: ['Ayu'],
          sender: 'console',
        ).toJson(),
      ),
    );
    expect(result.success, isTrue);
    expect(result.message, 'Hello Ayu (hi)');

    host.channel.notify(
      IpcMethod.event,
      const EventEnvelope(
        type: 'player.join',
        data: {'player': 'p1'},
        timestampMillis: 1,
      ).toJson(),
    );
    host.channel.notify(
      IpcMethod.event,
      const EventEnvelope(
        type: 'unrelated',
        data: {},
        timestampMillis: 2,
      ).toJson(),
    );
    await host.channel.request(IpcMethod.ping);
    expect(plugin.events.map((e) => e.data['player']), ['p1']);

    expect(await plugin.context.reloadConfig(), {'greeting': 'reloaded'});
    expect(plugin.context.timers.activeCount, 1);

    await host.shutdown();
    expect(await exitCode, PluginExitCode.ok);
    expect(plugin.calls, ['enable', 'disable']);
    expect(plugin.context.timers.activeCount, 0);
    await host.channel.done;
  });

  test('a failing onEnable surfaces as an init error', () async {
    final host = _FakeHost();
    final plugin = _Probe()..failEnable = true;
    final exitCode = runPlugin(plugin, options: host.pluginOptions);
    await host.hello.future;
    await expectLater(
      host.init(),
      throwsA(
        isA<IpcException>()
            .having((e) => e.code, 'code', IpcErrorCode.internal)
            .having((e) => e.message, 'message', contains('cannot enable')),
      ),
    );
    await host.channel.close();
    expect(await exitCode, PluginExitCode.hostLost);
  });

  test(
    'undeclared capabilities are refused locally before any request',
    () async {
      final host = _FakeHost();
      final plugin = _Probe();
      final exitCode = runPlugin(plugin, options: host.pluginOptions);
      await host.hello.future;
      await expectLater(
        host.init(capabilities: const []),
        throwsA(
          isA<IpcException>().having(
            (e) => e.message,
            'message',
            contains('commands'),
          ),
        ),
      );
      expect(host.registered, isEmpty);
      await host.channel.close();
      await exitCode;
    },
  );

  test('losing the host runs onDisable and exits with hostLost', () async {
    final host = _FakeHost();
    final plugin = _Probe();
    final exitCode = runPlugin(plugin, options: host.pluginOptions);
    await host.hello.future;
    await host.init();
    await host.channel.close();
    expect(await exitCode, PluginExitCode.hostLost);
    expect(plugin.calls, ['enable', 'disable']);
  });

  test('onDisable is bounded by the grace period', () async {
    final host = _FakeHost();
    final plugin = _Probe()..disableDelay = const Duration(seconds: 5);
    final exitCode = runPlugin(plugin, options: host.pluginOptions);
    await host.hello.future;
    await host.init();
    final watch = Stopwatch()..start();
    await host.shutdown(graceMillis: 100);
    expect(await exitCode, PluginExitCode.ok);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(
      host.logs.any(
        (l) => l.level == IpcLogLevel.error && l.message.contains('grace'),
      ),
      isTrue,
    );
  });

  test(
    'a declared listener is subscribed once and removed on shutdown',
    () async {
      final host = _FakeHost();
      final plugin = _ListedPlugin();
      final exitCode = runPlugin(plugin, options: host.pluginOptions);
      await host.hello.future;
      await host.init();
      expect(plugin.listenerReads, 1);
      expect(host.subscribed, ['demo.ping']);
      host.channel.notify(
        IpcMethod.event,
        const EventEnvelope(
          type: 'demo.ping',
          data: {'n': '1'},
          timestampMillis: 1,
        ).toJson(),
      );
      await host.channel.request(IpcMethod.ping);
      expect(plugin.listener.hits, 1);
      await expectLater(host.init(), throwsA(isA<IpcException>()));
      expect(host.subscribed, ['demo.ping']);
      await host.shutdown();
      expect(await exitCode, PluginExitCode.ok);
      expect(host.unsubscribed, ['demo.ping']);
      expect(plugin.listener.hits, 1);
    },
  );

  test('a host that never answers hello makes the worker give up', () async {
    final hostToPlugin = StreamController<List<int>>();
    final pluginToHost = StreamController<List<int>>();
    pluginToHost.stream.listen((_) {});
    final code = await runPlugin(
      _Probe(),
      options: PluginRunnerOptions(
        input: hostToPlugin.stream,
        output: IOSink(pluginToHost.sink),
        exitProcess: false,
        helloTimeout: const Duration(milliseconds: 200),
      ),
    );
    expect(code, PluginExitCode.protocol);
    await hostToPlugin.close();
  });
}
