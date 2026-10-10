import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late Directory packages;
  late PluginHost host;

  PluginHost newHost({PluginRuntimeOptions options = fastOptions}) => PluginHost(
        rootDirectory: Directory(p.join(temp.path, 'plugins')),
        options: options,
        runtime: jitRuntime,
        launcher: const JitFixtureLauncher(),
        logger: testLogger,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ayu_host_test_');
    packages = Directory(p.join(temp.path, 'pkg'))..createSync();
    host = newHost();
    await host.start();
  });

  tearDown(() async {
    await host.dispose();
    await temp.delete(recursive: true);
  });

  Future<File> pkg(String id, {String version = '1.0.0', String fixtureName = 'worker_ok', List<DependencySpec> deps = const []}) =>
      writeFixturePackage(packages, id: id, version: version, fixtureName: fixtureName, dependencies: deps);

  test('hot install activates the plugin and routes commands and events', () async {
    final states = <PluginStateChanged>[];
    host.events.where((e) => e is PluginStateChanged).cast<PluginStateChanged>().listen(states.add);

    final snapshot = await host.install(await pkg('alpha'));
    expect(snapshot.state, PluginState.active);
    expect(snapshot.enabled, isTrue);
    expect(snapshot.pid, isNotNull);
    expect(Directory(snapshot.installDirectory).existsSync(), isTrue);
    expect(host.layout.staging.listSync(), isEmpty, reason: 'staging is cleaned after commit');

    final echo = await host.executeCommand('echo', ['hello', 'world']);
    expect(echo.message, 'hello world');
    expect((await host.executeCommand('say', ['alias'])).message, 'alias');

    expect(host.emitEvent('test.event', {'n': 1}), 1);
    expect(host.emitEvent('other.event', {}), 0);
    expect((await host.executeCommand('events', [])).message, '1');

    await Future<void>.delayed(Duration.zero);
    expect(states.map((s) => s.to), containsAllInOrder([PluginState.staged, PluginState.starting, PluginState.active]));
  });

  test('install without enable stages the plugin disabled', () async {
    final snapshot = await host.install(await pkg('beta'), enable: false);
    expect(snapshot.state, PluginState.disabled);
    expect(snapshot.enabled, isFalse);
    expect(snapshot.pid, isNull);
    expect(host.registry.commands, isEmpty);
  });

  test('installing the same id twice is refused', () async {
    await host.install(await pkg('gamma'));
    await expectLater(
      host.install(await pkg('gamma')),
      throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.alreadyInstalled)),
    );
  });

  test('disable stops routing, terminates the worker and enable brings a fresh process', () async {
    final first = await host.install(await pkg('delta'));
    final firstPid = first.pid!;

    final disabled = await host.disable('delta');
    expect(disabled.state, PluginState.disabled);
    expect(disabled.pid, isNull);
    expect(disabled.lastExitCode, 0);
    expect(host.registry.commands, isEmpty);
    expect(host.emitEvent('test.event', {}), 0);
    await expectLater(host.executeCommand('echo', ['x']),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.commandNotFound)));
    expect(await processGone(firstPid), isTrue);
    expect((await host.disable('delta')).state, PluginState.disabled, reason: 'idempotent');

    final enabled = await host.enable('delta');
    expect(enabled.state, PluginState.active);
    expect(enabled.pid, isNot(firstPid));
    expect((await host.executeCommand('echo', ['again'])).message, 'again');
  });

  test('uninstall stops the worker and removes installed files but keeps data', () async {
    final snapshot = await host.install(await pkg('epsilon'));
    final data = Directory(snapshot.dataDirectory);
    File(p.join(data.path, 'keep.txt')).writeAsStringSync('user data');
    await host.uninstall('epsilon');
    expect(host.plugin('epsilon'), isNull);
    expect(Directory(snapshot.installDirectory).existsSync(), isFalse);
    expect(host.layout.pluginDirectory('epsilon').existsSync(), isFalse);
    expect(File(p.join(data.path, 'keep.txt')).existsSync(), isTrue);
    expect(await processGone(snapshot.pid!), isTrue);

    final reopened = newHost();
    await reopened.start();
    expect(reopened.plugins, isEmpty);
    await reopened.dispose();
  });

  test('update replaces the running version and removes the old files', () async {
    final v1 = await host.install(await pkg('zeta'));
    final v2 = await host.update(await pkg('zeta', version: '1.1.0'));
    expect(v2.version, Version(1, 1, 0));
    expect(v2.state, PluginState.active);
    expect(v2.pid, isNot(v1.pid));
    expect(Directory(v1.installDirectory).existsSync(), isFalse);
    expect(Directory(v2.installDirectory).existsSync(), isTrue);
    expect((await host.executeCommand('echo', ['v2'])).message, 'v2');
    await expectLater(host.update(await pkg('zeta', version: '1.1.0')),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.alreadyInstalled)));
  });

  test('a failing update rolls back to the previous version', () async {
    final v1 = await host.install(await pkg('eta'));
    await expectLater(
      host.update(await pkg('eta', version: '2.0.0', fixtureName: 'worker_fail_init')),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.updateFailed)
          .having((e) => e.details.join(), 'details', contains('fixture cannot enable'))),
    );
    final restored = host.plugin('eta')!;
    expect(restored.version, Version(1, 0, 0));
    expect(restored.state, PluginState.active);
    expect(Directory(v1.installDirectory).existsSync(), isTrue);
    expect(host.layout.installDirectory('eta', Version(2, 0, 0)).existsSync(), isFalse);
    expect((await host.executeCommand('echo', ['still here'])).message, 'still here');
  });

  test('a plugin that fails to start stays installed in the failed state with diagnostics', () async {
    final snapshot = await host.install(await pkg('theta', fixtureName: 'worker_fail_init')).then((s) => s, onError: (Object e) {
      expect(e, isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.startFailed));
      return host.plugin('theta')!;
    });
    expect(snapshot.state, PluginState.failed);
    expect(snapshot.lastError, contains('fixture cannot enable'));
    expect(snapshot.pid, isNull);
    expect(host.registry.commands, isEmpty);
    // The user can still remove it.
    await host.uninstall('theta');
    expect(host.plugin('theta'), isNull);
  });

  test('a crashing worker is detected, cleaned up and restarted within the budget', () async {
    await host.dispose();
    host = newHost(options: const PluginRuntimeOptions(
      helloTimeout: Duration(seconds: 8),
      initTimeout: Duration(seconds: 8),
      requestTimeout: Duration(seconds: 3),
      commandTimeout: Duration(seconds: 3),
      shutdownGracePeriod: Duration(seconds: 2),
      maxRestarts: 1,
      restartWindow: Duration(minutes: 5),
    ));
    await host.start();
    final crashed = Completer<void>();
    final restarted = Completer<void>();
    host.events.where((e) => e is PluginStateChanged).cast<PluginStateChanged>().listen((change) {
      if (change.to == PluginState.crashed && !crashed.isCompleted) crashed.complete();
      if (change.from == PluginState.starting && change.to == PluginState.active && crashed.isCompleted && !restarted.isCompleted) {
        restarted.complete();
      }
    });

    final first = await host.install(await pkg('iota'));
    expect((await host.executeCommand('crash', [])).message, 'crashing');
    await crashed.future.timeout(const Duration(seconds: 10));
    await restarted.future.timeout(const Duration(seconds: 15));

    final after = host.plugin('iota')!;
    expect(after.state, PluginState.active);
    expect(after.pid, isNot(first.pid));
    expect(after.restartCount, 1);
    expect(after.lastExitCode, 3);
    expect((await host.executeCommand('echo', ['back'])).message, 'back');

    // Budget exhausted: the second crash leaves it crashed.
    await host.executeCommand('crash', []);
    await host.events.where((e) => e is PluginStateChanged).cast<PluginStateChanged>().firstWhere((c) => c.to == PluginState.crashed).timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host.plugin('iota')!.state, PluginState.crashed);
    expect(host.registry.commands, isEmpty);
    expect((await host.enable('iota')).state, PluginState.active, reason: 'manual enable still works');
  });

  test('required dependencies gate install, disable and uninstall', () async {
    final needsAlpha = [DependencySpec(id: 'alpha', version: VersionConstraint.parse('^1.0.0'))];
    await expectLater(
      host.install(await pkg('dependent', fixtureName: 'worker_quiet', deps: needsAlpha)),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.dependency)
          .having((e) => e.details.join(), 'details', contains('"alpha"'))),
    );
    expect(host.plugin('dependent'), isNull);
    expect(host.layout.installed.listSync(), isEmpty, reason: 'nothing is staged before dependency checks pass');

    await host.install(await pkg('alpha'));
    expect((await host.install(await pkg('dependent', fixtureName: 'worker_quiet', deps: needsAlpha))).state, PluginState.active);

    await expectLater(host.disable('alpha'),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.dependency)));
    expect(host.plugin('alpha')!.state, PluginState.active);
    await expectLater(host.uninstall('alpha'),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.dependency)));
    await expectLater(host.update(await pkg('alpha', version: '2.0.0')),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.dependency)));

    await host.disable('dependent');
    expect((await host.disable('alpha')).state, PluginState.disabled);
    await expectLater(host.enable('dependent'),
        throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.dependency)));
    await host.enable('alpha');
    expect((await host.enable('dependent')).state, PluginState.active);
  });

  test('incompatible packages are rejected with actionable messages before anything is staged', () async {
    final otherTarget = RuntimeTarget.current().os == TargetOs.windows
        ? const RuntimeTarget(TargetOs.linux, TargetArch.x64)
        : const RuntimeTarget(TargetOs.windows, TargetArch.x64);
    await expectLater(
      host.install(await writeFixturePackage(packages, id: 'foreign', target: otherTarget)),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.incompatible)
          .having((e) => e.message, 'message', allOf(contains(RuntimeTarget.current().id), contains('ayu plugin build')))),
    );
    await expectLater(
      host.install(await writeFixturePackage(packages, id: 'oldsdk', dartSdk: Version(2, 19, 0))),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.incompatible)
          .having((e) => e.message, 'message', allOf(contains('2.19.0'), contains('rebuild')))),
    );
    await expectLater(
      host.install(await writeFixturePackage(packages, id: 'futureapi', api: '>=9.0.0 <10.0.0')),
      throwsA(isA<PluginHostException>()
          .having((e) => e.code, 'code', PluginHostErrorCode.incompatible)
          .having((e) => e.message, 'message', contains('plugin API'))),
    );
    expect(host.layout.installed.listSync(), isEmpty);
    expect(host.layout.staging.listSync(), isEmpty);
  });

  test('a package that is not a valid archive is rejected cleanly', () async {
    final bogus = File(p.join(packages.path, 'bogus.ayu'))..writeAsStringSync('definitely not a zip file' * 4);
    await expectLater(host.install(bogus),
        throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.invalidArchive)));
  });

  test('enabled plugins are restored in dependency order after a restart of the host', () async {
    await host.install(await pkg('alpha'));
    await host.install(await pkg('dependent', fixtureName: 'worker_quiet', deps: [DependencySpec(id: 'alpha', version: VersionConstraint.parse('^1.0.0'))]));
    await host.install(await pkg('sleepy'), enable: false);
    await host.dispose();

    final order = <String>[];
    host = newHost();
    host.events.where((e) => e is PluginStateChanged).cast<PluginStateChanged>().where((c) => c.to == PluginState.active).listen((c) => order.add(c.pluginId));
    await host.start();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['alpha', 'dependent']);
    expect(host.plugin('sleepy')!.state, PluginState.disabled);
    expect((await host.executeCommand('echo', ['restored'])).message, 'restored');
  });

  test('the host event loop stays responsive while a plugin starts', () async {
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) => ticks++);
    final watch = Stopwatch()..start();
    await host.install(await pkg('kappa'));
    timer.cancel();
    // A blocked event loop would deliver far fewer ticks than elapsed time allows.
    expect(ticks, greaterThan(watch.elapsedMilliseconds ~/ 20 ~/ 4));
  });

  test('config from the package is delivered and a data-directory override wins', () async {
    final configured = await writeFixturePackage(packages, id: 'lambda', extraEntries: {
      'config/config.json': Uint8List.fromList(utf8.encode('{"greeting":"from package"}')),
    });
    await host.install(configured);
    expect((await host.executeCommand('config', [])).message, 'from package');
    final data = Directory(host.plugin('lambda')!.dataDirectory);
    File(p.join(data.path, 'config.json')).writeAsStringSync('{"greeting":"from data"}');
    await host.disable('lambda');
    await host.enable('lambda');
    expect((await host.executeCommand('config', [])).message, 'from data');
  });
}
