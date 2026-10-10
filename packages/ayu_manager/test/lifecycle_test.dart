import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_manager/ayu_manager.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'fixture.dart';

final Directory _initialDirectory = Directory.current;

Directory workspaceRoot() {
  var dir = _initialDirectory;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir.path, 'start.bat')).existsSync() &&
        Directory(p.join(dir.path, 'packages', 'ayu_runtime')).existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  throw StateError('AyuMC workspace not found from ${_initialDirectory.path}');
}

String fixturePath(String name) => p.join(
  workspaceRoot().path,
  'packages',
  'ayu_runtime',
  'test',
  'fixtures',
  '$name.dart',
);

final String dartExecutable = () {
  final bin = File(Platform.resolvedExecutable).parent.path;
  final vm = File(p.join(bin, Platform.isWindows ? 'dartvm.exe' : 'dartvm'));
  return vm.existsSync() ? vm.path : Platform.resolvedExecutable;
}();

final Version sdkVersion = Version.parse(
  RegExp(
    r'^(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)',
  ).firstMatch(Platform.version)!.group(1)!,
);

final class SourceLauncher implements WorkerLauncher {
  const SourceLauncher();

  @override
  WorkerLaunchSpec launchSpec(PluginLaunchContext context) {
    final description = context.manifest.description ?? '';
    if (!description.startsWith('source:')) {
      throw PluginHostException(
        PluginHostErrorCode.startFailed,
        'expected a source: description',
      );
    }
    return WorkerLaunchSpec(
      executable: dartExecutable,
      arguments: [description.substring('source:'.length)],
      workingDirectory: context.dataDirectory.path,
    );
  }
}

void main() {
  test(
    'a stopped server can install, update, and uninstall without deleting the library file',
    () async {
      final root = await Directory.systemTemp.createTemp('ayu-disk-');
      addTearDown(() => root.delete(recursive: true));
      final library = Directory(p.join(root.path, 'library'));
      final original = await writePackage(
        library,
        id: 'alpha',
        version: '1.0.0',
      );
      final newer = await writePackage(
        library,
        id: 'alpha',
        version: '1.1.0',
        fileName: 'alpha-1.1.0.ayu',
      );
      final desk = PackageDesk(control: ServerControl(root: root));
      await desk.refresh();
      final installed = await desk.install(
        desk.inventory.library.singleWhere(
          (package) => package.manifest.version.toString() == '1.0.0',
        ),
        enable: false,
      );
      expect(installed.ok, isTrue, reason: installed.message);
      expect(installed.message, contains('disabled'));
      expect(desk.inventory.installed.single.enabled, isFalse);
      expect(desk.inventory.installed.single.state, isNull);

      final enabled = await desk.enable('alpha');
      expect(enabled.ok, isTrue, reason: enabled.message);
      expect(enabled.message, contains('not running'));
      expect(desk.inventory.installed.single.enabled, isTrue);
      expect(desk.inventory.installed.single.state, isNull);

      final disabled = await desk.disable('alpha');
      expect(disabled.ok, isTrue, reason: disabled.message);
      expect(desk.inventory.installed.single.enabled, isFalse);

      final updated = await desk.update(
        desk.inventory.library.singleWhere(
          (package) => package.manifest.version.toString() == '1.1.0',
        ),
      );
      expect(updated.ok, isTrue, reason: updated.message);
      expect(updated.message, contains('not a hot update'));
      expect(
        desk.inventory.installed.single.manifest.version,
        Version.parse('1.1.0'),
      );
      expect(
        Directory(
          p.join(root.path, 'plugins', 'installed', 'alpha', '1.0.0'),
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          p.join(root.path, 'plugins', 'installed', 'alpha', '1.1.0'),
        ).existsSync(),
        isTrue,
      );

      final data = File(
        p.join(root.path, 'plugins', 'data', 'alpha', 'keep.txt'),
      );
      await data.parent.create(recursive: true);
      await data.writeAsString('keep');
      final removed = await desk.uninstall('alpha');
      expect(removed.ok, isTrue, reason: removed.message);
      expect(desk.inventory.installed, isEmpty);
      expect(original.existsSync(), isTrue);
      expect(newer.existsSync(), isTrue);
      expect(data.existsSync(), isTrue);
      expect(
        Directory(
          p.join(root.path, 'plugins', 'installed', 'alpha'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'missing dependencies and unsupported targets are refused without installing',
    () async {
      final root = await Directory.systemTemp.createTemp('ayu-reject-');
      addTearDown(() => root.delete(recursive: true));
      final library = Directory(p.join(root.path, 'library'));
      final missing = await writePackage(
        library,
        id: 'needs_base',
        dependencies: [
          DependencySpec(
            id: 'base_pack',
            version: VersionConstraint.parse('^1.0.0'),
          ),
        ],
      );
      final foreign = await writePackage(
        library,
        id: 'foreign_only',
        target: foreignTarget,
        fileName: 'foreign.ayu',
      );
      final desk = PackageDesk(control: ServerControl(root: root));
      await desk.refresh();
      final missingPackage = desk.inventory.library.singleWhere(
        (package) => package.manifest.id == 'needs_base',
      );
      final foreignPackage = desk.inventory.library.singleWhere(
        (package) => package.manifest.id == 'foreign_only',
      );
      expect(
        foreignPackage.blockers.join(' '),
        contains('unsupported runtime target'),
      );
      final missingResult = await desk.install(missingPackage, enable: true);
      final foreignResult = await desk.install(foreignPackage, enable: true);
      expect(missingResult.ok, isFalse);
      expect(missingResult.message, contains('base_pack'));
      expect(foreignResult.ok, isFalse);
      expect(foreignResult.message, contains('unsupported runtime target'));
      expect(desk.inventory.installed, isEmpty);
      expect(missing.existsSync(), isTrue);
      expect(foreign.existsSync(), isTrue);
    },
  );

  test('changing screens does not wait for a package action', () async {
    final root = await Directory.systemTemp.createTemp('ayu-busy-');
    addTearDown(() => root.delete(recursive: true));
    final file = await writePackage(
      Directory(p.join(root.path, 'library')),
      id: 'slow',
    );
    final session = ManagerSession(control: ServerControl(root: root));
    await session.desk.refresh();
    final release = Completer<void>();
    final started = Completer<void>();
    session.desk.debugDelay = () async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final pending = session.desk.install(
      session.desk.inventory.library.single,
      enable: false,
    );
    await started.future;
    expect(session.desk.activity, isNotNull);
    session.section = ManagerSection.plugins;
    session.apply(const KeyEvent.text('5'));
    expect(session.section, ManagerSection.dashboard);
    release.complete();
    final result = await pending;
    expect(result.ok, isTrue, reason: result.message);
    expect(file.existsSync(), isTrue);
  });

  test(
    'parallel installs share one worker and lifecycle actions use the host',
    () async {
      final harness = await _host();
      addTearDown(harness.dispose);
      final package = await _sourcePackage(
        harness.library,
        id: 'alpha',
        fixture: 'worker_ok',
      );
      final desk = harness.desk;
      await desk.refresh();
      final opened = await AyuPackage.open(package);
      final item = _library(opened.manifest, package);
      await opened.close();
      final results = await Future.wait([
        desk.install(item, enable: true),
        desk.install(item, enable: true),
      ]);
      expect(results.where((result) => result.ok), hasLength(1));
      expect(
        harness.host.plugins.where((plugin) => plugin.id == 'alpha'),
        hasLength(1),
      );
      final running = harness.host.plugin('alpha')!;
      expect(running.state, PluginState.active);
      final pid = running.pid!;

      final disabled = await desk.disable('alpha');
      expect(disabled.ok, isTrue, reason: disabled.message);
      expect(harness.host.plugin('alpha')!.state, PluginState.disabled);
      expect(await processGone(pid), isTrue);

      final enabled = await desk.enable('alpha');
      expect(enabled.ok, isTrue, reason: enabled.message);
      expect(harness.host.plugin('alpha')!.state, PluginState.active);
      expect(harness.host.plugin('alpha')!.pid, isNot(pid));
    },
  );

  test(
    'a worker that fails to start stays installed and is not reported as active',
    () async {
      final harness = await _host();
      addTearDown(harness.dispose);
      final package = await _sourcePackage(
        harness.library,
        id: 'broken',
        fixture: 'worker_fail_init',
      );
      final opened = await AyuPackage.open(package);
      final result = await harness.desk.install(
        _library(opened.manifest, package),
        enable: true,
      );
      await opened.close();
      expect(result.ok, isFalse, reason: result.message);
      expect(result.message, contains('failed'));
      expect(harness.host.plugin('broken')!.state, PluginState.failed);
      expect(package.existsSync(), isTrue);
    },
  );

  test(
    'a worker that never completes hello is stopped and left failed',
    () async {
      final harness = await _host(hello: const Duration(milliseconds: 400));
      addTearDown(harness.dispose);
      final package = await _sourcePackage(
        harness.library,
        id: 'silent',
        fixture: 'worker_silent',
      );
      final opened = await AyuPackage.open(package);
      final result = await harness.desk.install(
        _library(opened.manifest, package),
        enable: true,
      );
      await opened.close();
      expect(result.ok, isFalse, reason: result.message);
      expect(result.message, contains('handshake'));
      final snapshot = harness.host.plugin('silent')!;
      expect(snapshot.state, PluginState.failed);
      if (snapshot.pid != null)
        expect(await processGone(snapshot.pid!), isTrue);
      expect(package.existsSync(), isTrue);
    },
  );

  test('a crashed worker is shown as crashed', () async {
    final harness = await _host();
    addTearDown(harness.dispose);
    final current = await _sourcePackage(
      harness.library,
      id: 'alpha',
      fixture: 'worker_ok',
    );
    final opened = await AyuPackage.open(current);
    final started = await harness.desk.install(
      _library(opened.manifest, current),
      enable: true,
    );
    await opened.close();
    expect(started.ok, isTrue, reason: started.message);
    final crashed = await harness.host.executeCommand('crash', const []);
    expect(crashed.success, isTrue);
    await _until(
      () => harness.host.plugin('alpha')?.state == PluginState.crashed,
    );
    await harness.desk.reload();
    expect(
      runtimeLabel(
        installed: true,
        serverRunning: true,
        enabled: true,
        state: harness.desk.inventory.installedById('alpha')!.state,
      ),
      contains('Crashed'),
    );
    expect(current.existsSync(), isTrue);
  });

  test('a failed hot update restores the previous active version', () async {
    final harness = await _host();
    addTearDown(harness.dispose);
    final current = await _sourcePackage(
      harness.library,
      id: 'alpha',
      fixture: 'worker_ok',
    );
    final next = await _sourcePackage(
      harness.library,
      id: 'alpha',
      version: '2.0.0',
      fixture: 'worker_fail_init',
      fileName: 'alpha-2.0.0.ayu',
    );
    final currentPackage = await AyuPackage.open(current);
    final nextPackage = await AyuPackage.open(next);
    final started = await harness.desk.install(
      _library(currentPackage.manifest, current),
      enable: true,
    );
    await currentPackage.close();
    expect(started.ok, isTrue, reason: started.message);
    expect(harness.host.plugin('alpha')!.state, PluginState.active);

    final updated = await harness.desk.update(
      _library(nextPackage.manifest, next),
    );
    await nextPackage.close();
    expect(updated.ok, isFalse, reason: updated.message);
    expect(harness.host.plugin('alpha')!.version, Version.parse('1.0.0'));
    expect(harness.host.plugin('alpha')!.state, PluginState.active);
    expect(next.existsSync(), isTrue);
    expect(current.existsSync(), isTrue);
  });

  test(
    'session packages are discovered, installed hot, and uninstalled without deleting sources',
    () async {
      final workspace = workspaceRoot();
      final sessionFile = File(
        p.join(
          workspace.path,
          'event_packs_src',
          'session_events',
          'build',
          'ayu',
          'session_events-1.0.0.ayu',
        ),
      );
      final auditFile = File(
        p.join(
          workspace.path,
          'examples',
          'session_audit_plugin',
          'build',
          'ayu',
          'session_audit-1.0.0.ayu',
        ),
      );
      final sessionSource = File(
        p.join(
          workspace.path,
          'event_packs_src',
          'session_events',
          'bin',
          'main.dart',
        ),
      );
      expect(sessionFile.existsSync(), isTrue);
      expect(auditFile.existsSync(), isTrue);
      final sessionBytes = await sessionFile.length();
      final sourceBytes = await sessionSource.length();

      final root = await Directory.systemTemp.createTemp('ayu-session-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final layout = ServerLayout(root);
      await layout.create();
      await layout.serverConfigFile.writeAsString(
        jsonEncode({'profile': 'AyuMC-1.8.9-release', 'port': 0}),
      );
      final control = ServerControl(root: root);
      addTearDown(() async {
        if (control.server != null) await control.stop();
      });
      final desk = PackageDesk(control: control, repositoryRoot: workspace);
      final previous = Directory.current;
      Directory.current = Directory.systemTemp.path;
      try {
        await desk.refresh();
      } finally {
        Directory.current = previous.path;
      }
      expect(desk.inventory.installed, isEmpty);
      expect(
        desk.inventory.library.map((package) => package.manifest.id),
        containsAll(['session_events', 'session_audit']),
      );
      final started = await control.start();
      expect(control.state, ServerRunState.running, reason: started);
      expect(control.server!.network, isNotNull);

      final logs = <String>[];
      final subscription = control.server!.plugins.events.listen((event) {
        if (event is PluginLogged)
          logs.add('${event.pluginId} ${event.message}');
      });
      addTearDown(subscription.cancel);

      final audit = await desk.install(
        _byId(desk, 'session_audit'),
        enable: true,
      );
      expect(audit.ok, isTrue, reason: audit.message);
      expect(
        control.server!.plugins.plugin('session_audit')!.state,
        PluginState.suspended,
      );

      final pack = await desk.install(
        _byId(desk, 'session_events'),
        enable: true,
      );
      expect(pack.ok, isTrue, reason: pack.message);
      await _until(
        () =>
            control.server!.plugins.plugin('session_audit')?.state ==
            PluginState.active,
      );
      expect(
        control.server!.plugins.plugin('session_events')!.state,
        PluginState.active,
      );
      expect(control.state, ServerRunState.running);

      control.server!.plugins.primitives.observe('core.session.play_joined', {
        'entityId': 7,
        'name': 'Steve',
        'uuid': 'abc',
      });
      await _until(
        () => logs.any(
          (line) => line.contains('PLAYER_JOINED') && line.contains('Steve'),
        ),
      );
      expect(
        logs.where((line) => line.contains('PLAYER_JOINED')),
        hasLength(1),
      );

      final disabled = await desk.disable('session_events', cascade: true);
      expect(disabled.ok, isTrue, reason: disabled.message);
      await _until(
        () =>
            control.server!.plugins.plugin('session_audit')?.state ==
            PluginState.suspended,
      );
      expect(
        control.server!.plugins.primitives.hasObservers(
          'core.session.play_joined',
        ),
        isFalse,
      );
      final joined = logs
          .where((line) => line.contains('PLAYER_JOINED'))
          .length;
      control.server!.plugins.primitives.observe('core.session.play_joined', {
        'entityId': 8,
        'name': 'Alex',
        'uuid': 'def',
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        logs.where((line) => line.contains('PLAYER_JOINED')),
        hasLength(joined),
      );

      final enabled = await desk.enable('session_events');
      expect(enabled.ok, isTrue, reason: enabled.message);
      await _until(
        () =>
            control.server!.plugins.plugin('session_audit')?.state ==
                PluginState.active &&
            control.server!.plugins.primitives.hasObservers(
              'core.session.play_joined',
            ),
      );
      control.server!.plugins.primitives.observe('core.session.play_joined', {
        'entityId': 9,
        'name': 'Bob',
        'uuid': 'ghi',
      });
      await _until(
        () =>
            logs.where((line) => line.contains('PLAYER_JOINED')).length ==
            joined + 1,
      );

      final data = File(
        p.join(
          control.server!.plugins.plugin('session_audit')!.dataDirectory,
          'keep.txt',
        ),
      );
      await data.writeAsString('keep');
      final removedAudit = await desk.uninstall('session_audit');
      expect(removedAudit.ok, isTrue, reason: removedAudit.message);
      final removedPack = await desk.uninstall('session_events');
      expect(removedPack.ok, isTrue, reason: removedPack.message);
      expect(control.server!.plugins.plugins, isEmpty);
      expect(await sessionFile.length(), sessionBytes);
      expect(await sessionSource.length(), sourceBytes);
      expect(auditFile.existsSync(), isTrue);
      expect(data.existsSync(), isTrue);
      expect(control.state, ServerRunState.running);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

LibraryPackage _byId(PackageDesk desk, String id) =>
    desk.inventory.library.singleWhere((package) => package.manifest.id == id);

LibraryPackage _library(PluginManifest manifest, File file) => LibraryPackage(
  file: file,
  manifest: manifest,
  blockers: compatibilityBlockers(
    manifest,
    ScanContext(
      profileId: 'AyuMC-1.8.9-release',
      apiVersion: Version.parse('1.0.0'),
      target: RuntimeTarget.current(),
      runtimeSdk: sdkVersion,
    ),
  ),
);

Future<File> _sourcePackage(
  Directory dir, {
  required String id,
  required String fixture,
  String version = '1.0.0',
  String? fileName,
}) {
  return writePackage(
    dir,
    id: id,
    version: version,
    fileName: fileName,
    description: 'source:${fixturePath(fixture)}',
    dartSdk: sdkVersion,
    capabilities: const {'commands', 'events'},
    events: [
      ContractRequirement(
        id: 'test.event',
        version: VersionConstraint.parse('^1.0.0'),
        optional: true,
      ),
    ],
  );
}

final class _Harness {
  _Harness(this.root, this.host, this.desk);

  final Directory root;
  final PluginHost host;
  final PackageDesk desk;
  Directory get library => Directory(p.join(root.path, 'library'));

  Future<void> dispose() async {
    await host.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<_Harness> _host({Duration hello = const Duration(seconds: 4)}) async {
  final root = await Directory.systemTemp.createTemp('ayu-host-');
  final host = PluginHost(
    rootDirectory: root,
    profileId: 'AyuMC-1.8.9-release',
    runtime: DartAotRuntime(
      executable: dartExecutable,
      version: sdkVersion,
      target: RuntimeTarget.current(),
    ),
    launcher: const SourceLauncher(),
    options: PluginRuntimeOptions(
      helloTimeout: hello,
      initTimeout: const Duration(seconds: 5),
      requestTimeout: const Duration(seconds: 3),
      commandTimeout: const Duration(seconds: 3),
      shutdownGracePeriod: const Duration(seconds: 2),
      killTimeout: const Duration(seconds: 3),
      restartOnCrash: false,
    ),
  );
  await host.start();
  final desk = PackageDesk(
    control: ServerControl(root: root),
    hostOverride: host,
  );
  return _Harness(root, host, desk);
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  fail('condition was not reached');
}

Future<bool> processGone(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!await _exists(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return !await _exists(pid);
}

Future<bool> _exists(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    return result.stdout.toString().contains('"$pid"');
  }
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}
