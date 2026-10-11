import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_core/ayu_core.dart';
import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the engine isolate starts, answers status once for coalesced calls, and stops',
    () async {
      final root = await Directory.systemTemp.createTemp('ayu-engine-');
      await _config(root, port: 0);
      final link = EngineLink(requestTimeout: const Duration(seconds: 15));
      addTearDown(() async {
        await link.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      });
      await link.open();
      final started = await link.start(root.path);
      expect(started['state'], 'running');
      expect(started['port'], greaterThan(0));

      final first = link.status();
      final second = link.status();
      final results = await Future.wait([first, second]);
      expect(results[0]['statusReads'], results[1]['statusReads']);
      expect(results[0]['statusReads'], 1);

      await link.command('ping');
      final order = <int>[];
      await Future.wait([
        link.command('ping').then((_) => order.add(1)),
        link.command('say hello').then((_) => order.add(2)),
      ]);
      expect(order, [1, 2]);

      final port = started['port'] as int;
      final steve = await _login(port, 'Steve');
      final alex = await _login(port, 'Alex');
      await alex.untilSpawn(steve.uuid);
      await steve.untilSpawn(alex.uuid);
      expect(alex.spawnFor(steve.uuid), isTrue);
      expect(steve.spawnFor(alex.uuid), isTrue);
      await steve.close();
      await alex.close();

      await link.stop();
      final stopped = await link.status();
      expect(stopped['state'], 'stopped');
      expect(stopped['sessions'], 0);
    },
  );

  test(
    'a bad profile fails startup without leaving the isolate hung',
    () async {
      final root = await Directory.systemTemp.createTemp('ayu-engine-bad-');
      await _config(root, port: 0, profile: 'not-a-profile');
      final link = EngineLink(requestTimeout: const Duration(seconds: 15));
      addTearDown(() async {
        await link.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      });
      await link.open();
      await expectLater(link.start(root.path), throwsA(isA<EngineException>()));
      final status = await link.status();
      expect(status['state'], 'stopped');
    },
  );

  test('too many in-flight control requests are refused', () async {
    final root = await Directory.systemTemp.createTemp('ayu-engine-bound-');
    await _config(root, port: 0);
    final link = EngineLink(requestTimeout: const Duration(seconds: 15));
    addTearDown(() async {
      await link.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });
    await link.open();
    await link.start(root.path);
    final results = await Future.wait([
      for (var i = 0; i < 20; i++)
        link.command('ping').then(
          (_) => 'ok',
          onError: (Object error) => '$error',
        ),
    ]);
    expect(
      results.where((line) => line.contains('too many control requests')),
      hasLength(20 - engineMaxInFlight),
    );
    expect(link.inFlight, lessThanOrEqualTo(engineMaxInFlight));
  });

  test(
    'killing the isolate is reported and does not leave the client waiting',
    () async {
      final root = await Directory.systemTemp.createTemp('ayu-engine-exit-');
      await _config(root, port: 0);
      final link = EngineLink(requestTimeout: const Duration(seconds: 15));
      addTearDown(() async {
        await link.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      });
      await link.open();
      await link.start(root.path);
      final pending = link.command('ping').then(
        (_) => 'ok',
        onError: (Object error) => '$error',
      );
      link.killForTest();
      await link.exited.timeout(const Duration(seconds: 5));
      final outcome = await pending.timeout(const Duration(seconds: 5));
      expect(
        outcome == 'ok' || outcome.contains('isolate'),
        isTrue,
        reason: outcome,
      );
      expect(link.isAlive, isFalse);
    },
  );
}

Future<void> _config(
  Directory root, {
  required int port,
  String profile = 'AyuMC-1.8.9-release',
}) async {
  await Directory('${root.path}/config').create(recursive: true);
  await File(
    '${root.path}/config/server.json',
  ).writeAsString('{"profile":"$profile","port":$port}');
}

Future<_Client> _login(int port, String name) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final client = _Client(socket, name);
  socket.add(
    encodePacket(0x00, [
      ...encodeVarInt(47),
      ...encodeString('localhost'),
      ...encodeUnsignedShort(25565),
      ...encodeVarInt(2),
    ]),
  );
  socket.add(encodePacket(0x00, encodeString(name)));
  await client.untilReady();
  return client;
}

final class _Client {
  _Client(this.socket, this.name) {
    subscription = socket.listen((chunk) {
      buffer.add(chunk);
      while (true) {
        final frame = buffer.readFrame();
        if (frame == null) return;
        frames.add(frame);
      }
    });
  }

  final Socket socket;
  final String name;
  final PacketBuffer buffer = PacketBuffer();
  final List<Uint8List> frames = [];
  late final StreamSubscription<List<int>> subscription;

  Uint8List get uuid => offlinePlayerUuidBytes(name);

  Future<void> untilReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (frames.length < 8) {
      if (DateTime.now().isAfter(deadline)) fail('$name did not enter play');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> untilSpawn(Uint8List other) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!spawnFor(other)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('$name did not see the other player');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool spawnFor(Uint8List uuid) {
    for (final frame in frames) {
      final body = PacketBuffer()..add(frame);
      if (body.readVarInt() != 0x0C) continue;
      body.readVarInt();
      final found = body.readBytes(16);
      if (_same(found, uuid)) return true;
    }
    return false;
  }

  Future<void> close() async {
    await subscription.cancel();
    socket.destroy();
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
