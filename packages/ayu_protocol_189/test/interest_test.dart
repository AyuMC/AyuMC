import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:test/test.dart';

void main() {
  test('fixed-point flooring drops motion smaller than 1/32 block', () {
    expect(fixedPoint(8.5), 272);
    expect(fixedPoint(8.5 + 1 / 64), 272);
    expect(fixedPoint(8.5 + 1 / 32), 273);
    expect(chunkCoord(8.5), 0);
    expect(chunkCoord(39.5), 2);
    expect(chunkCoord(41.5), 2);
    expect(chunkCoord(-0.1), -1);
    expect(angleByte(90), 64);
    expect(angleByte(-90), 256 - 64);
  });

  test(
    'a player in the next chunk is visible and one past the radius is not',
    () async {
      final index = ChunkIndex<PlaySession>();
      final visibility = ViewDistanceVisibility(serverChunks: 2);
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'interest',
        keepAliveInterval: const Duration(hours: 1),
        visibility: visibility,
      );
      await endpoint.bind(port: 0);
      final steve = await _Client.login(endpoint.port, 'Steve');
      final alex = await _Client.login(endpoint.port, 'Alex');
      try {
        await alex.untilSpawn(steve.uuid);
        expect(alex.spawns(steve.uuid), 1);
        expect(alex.tabAdds('Steve'), 1);

        steve.sendPosition(39.5, 16, 8.5);
        await alex.until((_) => alex.teleports > 0 || alex.moves > 0);
        expect(
          alex.destroys,
          0,
          reason: '31 blocks is inside a 2-chunk radius',
        );
        expect(alex.tabRemoves, 0);

        final before = alex.destroys;
        steve.sendPosition(41.5, 16, 8.5);
        await alex.until((_) => alex.destroys > before);
        expect(alex.destroys, before + 1);
        expect(
          alex.tabRemoves,
          0,
          reason: 'leaving range removes the entity, not the tab list',
        );
        expect(alex.spawns(steve.uuid), 1);

        steve.sendPosition(8.5, 16, 8.5);
        await alex.until((_) => alex.spawns(steve.uuid) == 2);
        expect(alex.spawns(steve.uuid), 2);
        expect(alex.tabAdds('Steve'), 1);
        index.move(endpoint.sessions.first, 0, 0);
      } finally {
        await steve.close();
        await alex.close();
        await endpoint.close();
      }
    },
  );

  test('client settings shrink the radius below the server cap', () async {
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'interest',
      keepAliveInterval: const Duration(hours: 1),
      visibility: const ViewDistanceVisibility(serverChunks: 10),
    );
    await endpoint.bind(port: 0);
    final steve = await _Client.login(endpoint.port, 'Steve');
    final alex = await _Client.login(endpoint.port, 'Alex');
    try {
      await alex.untilSpawn(steve.uuid);
      alex.sendSettings(2);
      await _until(
        () =>
            endpoint.sessions
                .singleWhere((s) => s.name == 'Alex')
                .clientViewChunks ==
            2,
      );
      steve.sendPosition(8.5 + 40, 16, 8.5);
      await alex.until((_) => alex.destroys == 1);
      expect(alex.tabRemoves, 0);
      expect(
        const ViewDistanceVisibility(
          serverChunks: 10,
        ).blocksFor(endpoint.sessions.singleWhere((s) => s.name == 'Alex')),
        32,
      );
    } finally {
      await steve.close();
      await alex.close();
      await endpoint.close();
    }
  });

  test(
    'all-visible mode still replicates a player outside the chunk radius',
    () async {
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'interest',
        keepAliveInterval: const Duration(hours: 1),
        visibility: const AllSessionsVisible(),
      );
      await endpoint.bind(port: 0);
      final steve = await _Client.login(endpoint.port, 'Steve');
      final alex = await _Client.login(endpoint.port, 'Alex');
      try {
        await alex.untilSpawn(steve.uuid);
        steve.sendPosition(8.5 + 40, 16, 8.5);
        await alex.until((_) => alex.teleports == 1);
        expect(alex.destroys, 0);
        expect(alex.tabRemoves, 0);
      } finally {
        await steve.close();
        await alex.close();
        await endpoint.close();
      }
    },
  );

  test('disconnect removes the tab entry and reconnect spawns once', () async {
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'interest',
      keepAliveInterval: const Duration(hours: 1),
      visibility: const ViewDistanceVisibility(serverChunks: 2),
    );
    await endpoint.bind(port: 0);
    final steve = await _Client.login(endpoint.port, 'Steve');
    final alex = await _Client.login(endpoint.port, 'Alex');
    try {
      await alex.untilSpawn(steve.uuid);
      final oldId = steve.entityId;
      await steve.close();
      await alex.until((_) => alex.destroys >= 1 && alex.tabRemoves >= 1);
      expect(alex.tabRemoves, 1);
      final again = await _Client.login(endpoint.port, 'Steve');
      try {
        await alex.until((_) => alex.spawns(again.uuid) == 2);
        expect(again.entityId, isNot(oldId));
        expect(alex.spawns(again.uuid), 2);
      } finally {
        await again.close();
      }
    } finally {
      await steve.close();
      await alex.close();
      await endpoint.close();
    }
  });

  test('paced replication keeps one baseline until the shared flush', () async {
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'interest',
      keepAliveInterval: const Duration(hours: 1),
      entityUpdateInterval: const Duration(hours: 1),
    );
    await endpoint.bind(port: 0);
    final steve = await _Client.login(endpoint.port, 'Steve');
    final alex = await _Client.login(endpoint.port, 'Alex');
    try {
      await alex.untilSpawn(steve.uuid);
      final before = alex.moves + alex.teleports;
      steve.sendPosition(9, 16, 8.5);
      steve.sendPosition(9.5, 16, 8.5);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(alex.moves + alex.teleports, before);
      endpoint.flushEntityReplication();
      await alex.until((_) => alex.moves + alex.teleports == before + 1);
      expect(alex.moves, before + 1);
      expect(alex.lastRelativeDx, 32);
    } finally {
      await steve.close();
      await alex.close();
      await endpoint.close();
    }
  });

  test(
    'sub-step motion is silent and a reversal uses a negative delta',
    () async {
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'interest',
        keepAliveInterval: const Duration(hours: 1),
      );
      await endpoint.bind(port: 0);
      final steve = await _Client.login(endpoint.port, 'Steve');
      final alex = await _Client.login(endpoint.port, 'Alex');
      try {
        await alex.untilSpawn(steve.uuid);
        final before = alex.moves;
        for (var step = 0; step < 10; step++) {
          steve.sendPosition(8.5 + 0.01, 16, 8.5);
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(alex.moves, before);
        steve.sendPosition(8.5 + 1 / 32, 16, 8.5);
        await alex.until((_) => alex.moves == before + 1);
        expect(alex.lastRelativeDx, 1);

        steve.sendPosition(9, 16, 8.5);
        await alex.until((_) => alex.moves == before + 2);
        steve.sendPosition(8.5, 16, 8.5);
        await alex.until((_) => alex.moves == before + 3);
        expect(alex.lastRelativeDx, -16);

        final looks = alex.looks;
        final heads = alex.heads;
        steve.sendLook(90, 0);
        await alex.until((_) => alex.looks == looks + 1 && alex.heads == heads + 1);
        steve.sendPosition(8.5 + 4, 16, 8.5);
        await alex.until((_) => alex.teleports == 1);
      } finally {
        await steve.close();
        await alex.close();
        await endpoint.close();
      }
    },
  );
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Client {
  _Client._(this.socket, this.name) {
    subscription = socket.listen((chunk) {
      buffer.add(chunk);
      while (true) {
        final frame = buffer.readFrame();
        if (frame == null) return;
        _take(frame);
      }
    }, onError: (_, _) {});
  }

  static Future<_Client> login(int port, String name) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final client = _Client._(socket, name);
    socket.add(
      encodePacket(0x00, [
        ...encodeVarInt(47),
        ...encodeString('localhost'),
        ...encodeUnsignedShort(25565),
        ...encodeVarInt(2),
      ]),
    );
    socket.add(encodePacket(0x00, encodeString(name)));
    await client.until((_) => client.entityId > 0);
    return client;
  }

  final Socket socket;
  final String name;
  final PacketBuffer buffer = PacketBuffer();
  late final StreamSubscription<List<int>> subscription;
  int entityId = 0;
  int moves = 0;
  int teleports = 0;
  int looks = 0;
  int heads = 0;
  int destroys = 0;
  int tabRemoves = 0;
  int lastRelativeDx = 0;
  final List<String> tabNames = [];
  final List<Uint8List> spawned = [];

  Uint8List get uuid => offlinePlayerUuidBytes(name);

  int spawns(Uint8List id) => spawned.where((value) => _same(value, id)).length;

  int tabAdds(String player) =>
      tabNames.where((value) => value == player).length;

  void sendPosition(double x, double y, double z) {
    socket.add(
      encodePacket(0x04, [
        ...encodeDouble(x),
        ...encodeDouble(y),
        ...encodeDouble(z),
        1,
      ]),
    );
  }

  void sendLook(double yaw, double pitch) {
    socket.add(
      encodePacket(0x05, [...encodeFloat(yaw), ...encodeFloat(pitch), 1]),
    );
  }

  void sendSettings(int viewChunks) {
    socket.add(
      encodePacket(0x15, [...encodeString('en_US'), viewChunks, 0, 1, 0x7F]),
    );
  }

  Future<void> until(bool Function(_Client client) ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!ready(this)) {
      if (DateTime.now().isAfter(deadline)) fail('$name timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> untilSpawn(Uint8List id) => until((_) => spawns(id) > 0);

  Future<void> close() async {
    await subscription.cancel();
    socket.destroy();
  }

  void _take(Uint8List frame) {
    final body = PacketBuffer()..add(frame);
    final id = body.readVarInt();
    switch (id) {
      case 0x01:
        if (frame.length >= 5) {
          entityId = ByteData.sublistView(frame).getInt32(1);
        }
        break;
      case 0x0C:
        body.readVarInt();
        spawned.add(body.readBytes(16));
        break;
      case 0x13:
        destroys += body.readVarInt();
        break;
      case 0x15:
        body.readVarInt();
        lastRelativeDx = _signed(body.readUnsignedByte());
        moves++;
        break;
      case 0x16:
        looks++;
        break;
      case 0x18:
        teleports++;
        break;
      case 0x19:
        heads++;
        break;
      case 0x38:
        final action = body.readVarInt();
        body.readVarInt();
        body.readBytes(16);
        if (action == 0) {
          tabNames.add(body.readString());
        } else if (action == 4) {
          tabRemoves++;
        }
        break;
    }
  }
}

int _signed(int value) => value > 127 ? value - 256 : value;

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
