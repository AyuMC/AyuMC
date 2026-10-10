import 'dart:io';

import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late Directory packages;
  late PluginHost host;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ayu_event_host_');
    packages = Directory(p.join(temp.path, 'pkg'))..createSync();
    host = PluginHost(
      rootDirectory: temp,
      profileId: testProfileId,
      runtime: jitRuntime,
      launcher: const JitFixtureLauncher(),
      logger: testLogger,
      options: fastOptions,
    );
    await host.start();
  });

  tearDown(() async {
    await host.dispose();
    await temp.delete(recursive: true);
  });

  Future<File> pack({String id = 'login_pack', String fixtureName = 'worker_login_pack'}) {
    return writeFixturePackage(
      packages,
      id: id,
      fixtureName: fixtureName,
      packageType: PackageType.eventPack,
      profiles: const [testProfileId],
      capabilities: const {'observe', 'publish'},
      provides: [
        EventContractSpec(
          id: 'session.login_started',
          version: Version(1, 0, 0),
          delivery: const DeliverySpec(),
          sources: const ['core.session.login'],
          schema: const {'name': 'string'},
        ),
      ],
    );
  }

  Future<File> consumer({bool required = true}) {
    return writeFixturePackage(
      packages,
      id: 'login_counter',
      fixtureName: 'worker_login_plugin',
      capabilities: const {'commands', 'events'},
      events: [
        ContractRequirement(id: 'session.login_started', version: VersionConstraint.parse('^1.0.0'), optional: !required),
      ],
    );
  }

  Future<String> logins() async => (await host.executeCommand('logins', [])).message!;

  test('a base host has no gameplay contracts and stays up', () {
    expect(host.contracts.describe(), isEmpty);
    expect(host.eventPacks, isEmpty);
    expect(host.primitives.hasObservers('core.session.login'), isFalse);
  });

  test('installing a pack then a plugin delivers a primitive as a contract, and disabling stops it', () async {
    expect((await host.install(await consumer())).state, PluginState.suspended);

    final installedPack = await host.install(await pack());
    expect(installedPack.state, PluginState.active);
    expect(host.plugin('login_counter')!.state, PluginState.active, reason: 'resumed once the contract exists');
    expect(host.contracts.provider('session.login_started')?.providerId, 'login_pack');

    host.primitives.observe('core.session.login', {'name': 'Steve'});
    await _until(() async => await logins() == '1');

    await expectLater(
      host.disable('login_pack'),
      throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.dependency)),
    );
    expect((await host.disable('login_pack', cascade: true)).state, PluginState.disabled);
    expect(host.plugin('login_counter')!.state, PluginState.suspended);
    expect(host.contracts.provider('session.login_started'), isNull);

    host.primitives.observe('core.session.login', {'name': 'Alex'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.plugin('login_counter')!.state, PluginState.suspended);

    await host.enable('login_pack');
    expect(host.plugin('login_counter')!.state, PluginState.active);
    expect(await logins(), '0', reason: 'resume starts a fresh worker');
  });

  test('a pack for another profile and a pack that fails to start leave the host usable', () async {
    await expectLater(
      host.install(await writeFixturePackage(
        packages,
        id: 'foreign_pack',
        packageType: PackageType.eventPack,
        profiles: const ['AyuMC-other-release'],
        capabilities: const {'observe', 'publish'},
        provides: [
          EventContractSpec(id: 'session.login_started', version: Version(1, 0, 0), delivery: const DeliverySpec()),
        ],
      )),
      throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.incompatible)),
    );
    expect(host.plugin('foreign_pack'), isNull);

    await expectLater(
      host.install(await pack(id: 'broken_pack', fixtureName: 'worker_fail_init')),
      throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.startFailed)),
    );
    expect(host.plugin('broken_pack')!.state, PluginState.failed);
    expect(host.contracts.describe(), isEmpty);
    expect((await host.install(await pack())).state, PluginState.active);
  });

  test('two packs cannot provide the same contract at once', () async {
    await host.install(await pack());
    await expectLater(
      host.install(await pack(id: 'second_pack')),
      throwsA(isA<PluginHostException>().having((e) => e.code, 'code', PluginHostErrorCode.conflict)),
    );
    expect(host.plugin('second_pack'), isNull);
    expect(host.layout.events.installed.listSync().map((e) => p.basename(e.path)), ['login_pack']);
  });
}

Future<void> _until(Future<bool> Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met within $timeout');
}
