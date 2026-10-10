import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:ayu_runtime/src/worker_process.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  final started = <WorkerProcess>[];

  setUp(() async => temp = await Directory.systemTemp.createTemp('ayu_worker_test_'));

  tearDown(() async {
    for (final worker in started) {
      if (!worker.hasExited) await worker.kill();
      await worker.dispose();
    }
    started.clear();
    await temp.delete(recursive: true);
  });

  Future<WorkerProcess> launch(String fixtureName, {PluginRuntimeOptions options = fastOptions}) async {
    final worker = await WorkerProcess.start(
      WorkerLaunchSpec(executable: dartExecutable, arguments: [fixture(fixtureName)], workingDirectory: temp.path),
      options: options,
      log: testLogger,
      debugName: fixtureName,
      hostVersion: 'test',
    );
    started.add(worker);
    return worker;
  }

  InitRequest initFor(String id) => InitRequest(
        plugin: PluginDescriptor(id: id, name: id, version: '1.0.0'),
        installDirectory: temp.path,
        dataDirectory: temp.path,
        capabilities: const ['commands', 'events', 'config'],
        config: const {'greeting': 'hi'},
      );

  test('well-behaved worker completes handshake, init, requests and graceful shutdown', () async {
    final worker = await launch('worker_ok');
    final registered = <String>[];
    worker.requestHandler = (method, params) {
      if (method == IpcMethod.commandRegister) registered.add(CommandSpec.fromJson(params).name);
      return null;
    };
    final hello = await worker.awaitHello();
    expect(hello.protocolVersions, contains(IpcProtocol.version));
    expect(hello.pid, worker.pid);

    await worker.init(initFor('ok'));
    expect(registered, containsAll(['echo', 'events', 'crash', 'spin']));
    await worker.channel.request(IpcMethod.ping);

    final watch = Stopwatch()..start();
    expect(await worker.terminate(reason: 'test'), TerminationOutcome.exitedGracefully);
    expect(worker.exitCode, 0);
    expect(watch.elapsed, lessThan(fastOptions.shutdownGracePeriod));
    expect(await processGone(worker.pid), isTrue);
  });

  test('a worker that never speaks is rejected at the hello deadline and killed', () async {
    const options = PluginRuntimeOptions(helloTimeout: Duration(seconds: 2), killTimeout: Duration(seconds: 5));
    final worker = await launch('worker_silent', options: options);
    final watch = Stopwatch()..start();
    await expectLater(
      worker.awaitHello(),
      throwsA(isA<WorkerStartException>().having((e) => e.message, 'message', contains('handshake'))),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
    expect(worker.hasExited, isFalse, reason: 'silent worker is alive until killed');
    expect(await worker.kill(), TerminationOutcome.killed);
    expect(await processGone(worker.pid), isTrue);
  });

  test('a worker that corrupts the protocol stream is detected before the deadline', () async {
    final worker = await launch('worker_garbage');
    final watch = Stopwatch()..start();
    await expectLater(
      worker.awaitHello(),
      throwsA(isA<WorkerStartException>().having((e) => e.message, 'message', contains('channel closed'))),
    );
    expect(watch.elapsed, lessThan(fastOptions.helloTimeout));
    expect(worker.channel.closeReason?.kind, ChannelCloseKind.protocolError);
    expect(await worker.kill(), isIn([TerminationOutcome.killed, TerminationOutcome.alreadyExited]));
  });

  test('a worker that exits early reports its exit code and stderr', () async {
    final worker = await launch('worker_exit_early');
    await expectLater(
      worker.awaitHello(),
      throwsA(isA<WorkerStartException>()
          .having((e) => e.exitCode, 'exitCode', 7)
          .having((e) => e.stderrTail, 'stderr', contains('fixture refuses to start'))),
    );
    expect(await worker.terminate(reason: 'test'), TerminationOutcome.alreadyExited);
  });

  test('a plugin whose onEnable throws fails init with the error message', () async {
    final worker = await launch('worker_fail_init');
    await worker.awaitHello();
    await expectLater(
      worker.init(initFor('bad')),
      throwsA(isA<WorkerStartException>().having((e) => e.message, 'message', contains('fixture cannot enable'))),
    );
    expect(await worker.kill(), TerminationOutcome.killed);
  });

  test('a worker that blocks its event loop is killed within the configured bounds', () async {
    final worker = await launch('worker_ok');
    worker.requestHandler = (_, _) => null;
    await worker.awaitHello();
    await worker.init(initFor('busy'));
    // The spin command never returns; the request times out while the
    // worker keeps burning CPU and can no longer answer shutdown.
    await expectLater(
      worker.channel.request(IpcMethod.commandExecute,
          CommandInvocation(name: 'spin', args: const [], sender: 'test').toJson(), const Duration(milliseconds: 500)),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.timeout)),
    );
    final watch = Stopwatch()..start();
    expect(await worker.terminate(reason: 'test'), TerminationOutcome.killed);
    expect(watch.elapsed, lessThan(fastOptions.shutdownGracePeriod + fastOptions.killTimeout + const Duration(seconds: 2)));
    expect(await processGone(worker.pid), isTrue);
  });

  test('a malformed artifact under the real dartaotruntime fails fast instead of hanging', () async {
    final probe = await const DartRuntimeLocator().probe(
        '${File(dartExecutable).parent.path}${Platform.pathSeparator}dartaotruntime${Platform.isWindows ? '.exe' : ''}');
    final runtime = probe.runtime;
    if (runtime == null) {
      markTestSkipped('dartaotruntime not found next to the Dart VM: ${probe.failure}');
      return;
    }
    final bogus = File('${temp.path}${Platform.pathSeparator}plugin.aot')..writeAsStringSync('this is not a snapshot');
    final worker = await WorkerProcess.start(
      WorkerLaunchSpec(executable: runtime.executable, arguments: [bogus.path], workingDirectory: temp.path),
      options: fastOptions,
      log: testLogger,
      debugName: 'bogus',
      hostVersion: 'test',
    );
    started.add(worker);
    final watch = Stopwatch()..start();
    await expectLater(
      worker.awaitHello(),
      throwsA(isA<WorkerStartException>()
          .having((e) => e.exitCode, 'exitCode', isNot(0))
          .having((e) => e.stderrTail, 'stderr', contains('not an AOT snapshot'))),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(worker.hasExited, isTrue);
  });
}
