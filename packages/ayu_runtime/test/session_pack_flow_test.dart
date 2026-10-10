import 'dart:io';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Drives the real session Event Pack source and the real audit plugin
/// through a simulated 1.8.9 client. This is not a test of the official game.
void main() {
  late Directory temp;
  late Directory packages;
  late PluginHost host;
  late ProtocolEndpoint endpoint;
  late _RecordingLogger logs;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ayu_session_flow_');
    packages = Directory(p.join(temp.path, 'pkg'))..createSync();
    logs = _RecordingLogger();
    host = PluginHost(
      rootDirectory: temp,
      profileId: testProfileId,
      runtime: jitRuntime,
      launcher: const JitFixtureLauncher(),
      logger: logs,
      options: fastOptions,
    );
    await host.start();
    endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'test',
      keepAliveInterval: const Duration(hours: 1),
      interestedIn: (id) => host.primitives.hasObservers(id) || host.primitives.hasDeciders(id),
      onPrimitive: (id, data) {
        if (host.primitives.hasDeciders(id)) {
          host.primitives.decide(id, data);
        } else if (host.primitives.hasObservers(id)) {
          host.primitives.observe(id, data);
        }
      },
    );
    await endpoint.bind(port: 0);
  });

  tearDown(() async {
    await endpoint.close();
    await host.dispose();
    await temp.delete(recursive: true);
  });

  test('join and leave are delivered once, and disappear when the pack is disabled', () async {
    expect(host.eventPacks, isEmpty);
    expect(endpoint.sessions, isEmpty);

    final audit = await host.install(await _auditPackage(packages));
    expect(audit.state, PluginState.suspended, reason: 'required session contracts have no provider yet');

    final pack = await host.install(await _packPackage(packages));
    expect(pack.state, PluginState.active);
    expect(host.plugin('session_audit')!.state, PluginState.active);
    expect(host.contracts.provider('session.joined')?.providerId, 'session_events');

    await _login(endpoint.port, 'Steve');
    await _until(() => logs.count('PLAYER_JOINED username=Steve') == 1 && logs.count('PLAYER_LEFT username=Steve') == 1);
    expect(logs.count('PLAYER_JOINED'), 1);
    expect(logs.count('PLAYER_LEFT'), 1);

    await host.disable('session_events', cascade: true);
    expect(host.plugin('session_audit')!.state, PluginState.suspended);
    final joinedBefore = logs.count('PLAYER_JOINED');
    final leftBefore = logs.count('PLAYER_LEFT');
    await _login(endpoint.port, 'Alex');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(logs.count('PLAYER_JOINED'), joinedBefore);
    expect(logs.count('PLAYER_LEFT'), leftBefore);

    await host.enable('session_events');
    expect(host.plugin('session_audit')!.state, PluginState.active);
    await _login(endpoint.port, 'Bob');
    await _until(() => logs.count('PLAYER_JOINED username=Bob') == 1 && logs.count('PLAYER_LEFT username=Bob') == 1);
  });
}

Future<File> _packPackage(Directory dir) {
  final source = p.normalize(p.absolute(p.join('..', '..', 'event_packs_src', 'session_events', 'bin', 'main.dart')));
  return writeFixturePackage(
    dir,
    id: 'session_events',
    packageType: PackageType.eventPack,
    profiles: const [testProfileId],
    capabilities: const {'observe', 'publish'},
    description: 'source:$source',
    provides: [
      EventContractSpec(
        id: 'session.joined',
        version: Version(1, 0, 0),
        delivery: const DeliverySpec(),
        sources: const ['core.session.play_joined'],
        schema: const {'entityId': 'int', 'name': 'string', 'uuid': 'string'},
      ),
      EventContractSpec(
        id: 'session.left',
        version: Version(1, 0, 0),
        delivery: const DeliverySpec(),
        sources: const ['core.session.closed'],
        schema: const {'entityId': 'int', 'name': 'string', 'uuid': 'string'},
      ),
    ],
  );
}

Future<File> _auditPackage(Directory dir) {
  final source = p.normalize(p.absolute(p.join('..', '..', 'examples', 'session_audit_plugin', 'bin', 'main.dart')));
  return writeFixturePackage(
    dir,
    id: 'session_audit',
    capabilities: const {'events'},
    description: 'source:$source',
    events: [
      ContractRequirement(id: 'session.joined', version: VersionConstraint.parse('^1.0.0')),
      ContractRequirement(id: 'session.left', version: VersionConstraint.parse('^1.0.0')),
    ],
  );
}

Future<void> _login(int port, String name) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.add(encodePacket(0x00, [
    ...encodeVarInt(47),
    ...encodeString('localhost'),
    ...encodeUnsignedShort(25565),
    ...encodeVarInt(2),
  ]));
  socket.add(encodePacket(0x00, encodeString(name)));
  final buffer = PacketBuffer();
  var frames = 0;
  await socket.timeout(const Duration(seconds: 3)).forEach((chunk) {
    buffer.add(chunk);
    while (buffer.readFrame() != null) {
      frames++;
    }
    if (frames >= 8) socket.destroy();
  });
  expect(frames, greaterThanOrEqualTo(8));
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _RecordingLogger extends Logger {
  _RecordingLogger() : super('test');

  final List<String> lines = [];

  @override
  void info(String message) => lines.add(message);

  @override
  void warn(String message) => lines.add(message);

  @override
  void error(String message) => lines.add(message);

  int count(String fragment) => lines.where((line) => line.contains(fragment)).length;
}
