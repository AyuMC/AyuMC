import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

EventContractSpec contract(String id, {String version = '1.0.0', List<String> sources = const ['core.session.login']}) =>
    EventContractSpec(id: id, version: Version.parse(version), delivery: const DeliverySpec(), sources: sources);

void main() {
  late ContractRegistry registry;

  setUp(() => registry = ContractRegistry());

  test('one provider per contract, removal is complete', () {
    registry.registerProvider('pack', [contract('session.login_started'), contract('session.closed')]);
    expect(() => registry.registerProvider('other', [contract('session.login_started')]), throwsA(isA<PluginHostException>()));
    expect(registry.provider('session.closed')?.providerId, 'pack');
    expect(registry.unregisterProvider('pack'), ['session.login_started', 'session.closed']);
    expect(registry.provider('session.login_started'), isNull);
    registry.registerProvider('other', [contract('session.login_started', version: '1.1.0')]);
    expect(registry.provider('session.login_started')?.spec.version, Version(1, 1, 0));
  });

  test('requirements distinguish missing and incompatible providers', () {
    final needs = PluginManifest(
      id: 'consumer',
      name: 'Consumer',
      version: Version(1, 0, 0),
      api: VersionConstraint.parse('^1.0.0'),
      events: [
        ContractRequirement(id: 'session.login_started', version: VersionConstraint.parse('^1.0.0')),
        ContractRequirement(id: 'session.closed', version: VersionConstraint.parse('^2.0.0')),
      ],
    );
    expect(registry.unsatisfiedRequirements(needs), hasLength(2));
    registry.registerProvider('pack', [contract('session.login_started'), contract('session.closed', version: '1.0.0')]);
    expect(registry.unsatisfiedRequirements(needs).single, contains('does not satisfy'));
  });

  test('a plugin can subscribe only to contracts it declared', () {
    registry.declareRequirements('consumer', [
      ContractRequirement(id: 'session.login_started', version: VersionConstraint.parse('^1.0.0')),
    ]);
    expect(() => registry.subscribe('consumer', 'session.closed'), throwsA(isA<IpcException>()));
    registry.subscribe('consumer', 'session.login_started');
    expect(registry.subscribers('session.login_started'), ['consumer']);
    registry.removeConsumer('consumer');
    expect(registry.subscribers('session.login_started'), isEmpty);
  });

  test('primitive observation is limited to declared sources and reports demand', () {
    final manifest = PluginManifest(
      id: 'pack',
      name: 'Pack',
      version: Version(1, 0, 0),
      api: VersionConstraint.parse('^1.0.0'),
      packageType: PackageType.eventPack,
      profiles: const ['AyuMC-1.8.9-release'],
      provides: [contract('session.login_started')],
    );
    registry.registerProvider('pack', manifest.provides);
    expect(() => registry.subscribePrimitive('pack', 'core.other', manifest), throwsA(isA<IpcException>()));
    registry.subscribePrimitive('pack', 'core.session.login', manifest);
    expect(registry.hasDemand('pack', 'core.session.login'), isFalse, reason: 'nobody subscribed yet');
    registry.declareRequirements('consumer', [
      ContractRequirement(id: 'session.login_started', version: VersionConstraint.parse('^1.0.0')),
    ]);
    registry.subscribe('consumer', 'session.login_started');
    expect(registry.hasDemand('pack', 'core.session.login'), isTrue);
    expect(registry.consumersRequiring(['session.login_started']), ['consumer']);
  });
}
