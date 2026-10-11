import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:test/test.dart';

void main() {
  test('the first client logs into the stone pad', () async {
    await _with(1, (endpoint, players) async {
      final steve = players.single;
      expect(endpoint.sessions.single.name, 'Steve');
      expect(endpoint.sessions.single.uuid, offlinePlayerUuid('Steve'));
      expect(steve.entityId, endpoint.sessions.single.entityId);
      expect(steve.loginUuid, offlinePlayerUuid('Steve'));
      expect(steve.ids, contains(0x21));
      expect(steve.spawnsOf(steve.uuidBytes), isEmpty);
    });
  });

  test(
    'a second client is introduced with the player list before the spawn',
    () async {
      await _with(2, (endpoint, players) async {
        final steve = players[0];
        final alex = players[1];
        final packets = steve.decoded;
        final listAt = packets.indexWhere(
          (p) => p is TabAdd && p.name == 'Alex',
        );
        final spawnAt = packets.indexWhere(
          (p) => p is Spawn && _same(p.uuid, alex.uuidBytes),
        );
        final intro = packets[listAt] as TabAdd;
        final spawn = packets[spawnAt] as Spawn;
        expect(intro.uuid, alex.uuidBytes);
        expect(intro.gamemode, 0);
        expect(listAt, lessThan(spawnAt));
        expect(spawn.entityId, alex.entityId);
        expect(spawn.x, 272);
        expect(spawn.y, 512);
        expect(spawn.z, 272);
        expect(spawn.item, 0);
        expect(spawn.flags, 0);
        expect(endpoint.sessions.map((s) => s.entityId).toSet(), {
          steve.entityId,
          alex.entityId,
        });
      });
    },
  );

  test('the joining client sees the player who was already online', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final packets = alex.decoded;
      final listAt = packets.indexWhere(
        (p) => p is TabAdd && p.name == 'Steve',
      );
      final spawnAt = packets.indexWhere(
        (p) => p is Spawn && _same(p.uuid, steve.uuidBytes),
      );
      final spawn = packets[spawnAt] as Spawn;
      expect(listAt, greaterThanOrEqualTo(0));
      expect(listAt, lessThan(spawnAt));
      expect(spawn.entityId, steve.entityId);
      expect(spawn.x, 272);
      expect(spawn.y, 512);
      expect(spawn.z, 272);
      expect(alex.spawnsOf(alex.uuidBytes), isEmpty);
      expect(steve.spawnsOf(steve.uuidBytes), isEmpty);
    });
  });

  test(
    'a short move is one relative update and is not echoed to the sender',
    () async {
      await _with(2, (endpoint, players) async {
        final steve = players[0];
        final alex = players[1];
        final before = alex.frames.length;
        final self = steve.frames.length;
        final encodes = endpoint.replicationEncodes;
        final deliveries = endpoint.replicationDeliveries;
        steve.sendPosition(9, 16, 8.5);
        await alex.until(
          (_) => alex.movesOf(steve.entityId, from: before).isNotEmpty,
        );
        final move = alex.movesOf(steve.entityId, from: before).single;
        expect(move, isA<RelMove>());
        final relative = move as RelMove;
        expect(relative.dx, 16);
        expect(relative.dy, 0);
        expect(relative.dz, 0);
        expect(relative.onGround, isTrue);
        expect(alex.teleportsOf(steve.entityId, from: before), isEmpty);
        expect(steve.movesOf(steve.entityId, from: self), isEmpty);
        expect(endpoint.replicationEncodes - encodes, 1);
        expect(endpoint.replicationDeliveries - deliveries, 1);
        expect(endpoint.sessions.singleWhere((s) => s.name == 'Steve').x, 9);

        final after = alex.frames.length;
        steve.sendPosition(9, 16, 8.5);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alex.movesOf(steve.entityId, from: after), isEmpty);
      });
    },
  );

  test('rotation only uses entity look and head look', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final before = alex.frames.length;
      final self = steve.frames.length;
      steve.sendLook(90, 45);
      await alex.until(
        (_) => alex.looksOf(steve.entityId, from: before).isNotEmpty,
      );
      final look = alex.looksOf(steve.entityId, from: before).single;
      expect(look.yaw, 64);
      expect(look.pitch, 32);
      expect(look.onGround, isTrue);
      final head = alex.headsOf(steve.entityId, from: before).single;
      expect(head.yaw, 64);
      expect(alex.decodedFrom(before).whereType<RelMove>(), isEmpty);
      expect(alex.decodedFrom(before).whereType<LookMove>(), isEmpty);
      expect(alex.decodedFrom(before).whereType<Teleport>(), isEmpty);
      expect(steve.looksOf(steve.entityId, from: self), isEmpty);
      expect(steve.headsOf(steve.entityId, from: self), isEmpty);
    });
  });

  test('position and rotation share one look-move packet', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final before = alex.frames.length;
      final encodes = endpoint.replicationEncodes;
      steve.sendPositionAndLook(9, 16, 8.5, yaw: 90, pitch: 0);
      await alex.until(
        (_) => alex.decodedFrom(before).whereType<LookMove>().isNotEmpty,
      );
      final move = alex.decodedFrom(before).whereType<LookMove>().single;
      expect(move.entityId, steve.entityId);
      expect(move.dx, 16);
      expect(move.dy, 0);
      expect(move.dz, 0);
      expect(move.yaw, 64);
      expect(move.pitch, 0);
      expect(alex.headsOf(steve.entityId, from: before).single.yaw, 64);
      expect(alex.decodedFrom(before).whereType<RelMove>(), isEmpty);
      expect(alex.decodedFrom(before).whereType<Look>(), isEmpty);
      expect(endpoint.replicationEncodes - encodes, 2);
    });
  });

  test('a delta of 127 stays relative and 128 becomes a teleport', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final before = alex.frames.length;
      steve.sendPosition(8.5 + 127 / 32, 16, 8.5);
      await alex.until(
        (_) => alex.movesOf(steve.entityId, from: before).isNotEmpty,
      );
      final relative = alex.decodedFrom(before).whereType<RelMove>().single;
      expect(relative.dx, 127);
      expect(alex.decodedFrom(before).whereType<Teleport>(), isEmpty);

      final next = alex.frames.length;
      steve.sendPosition(8.5 + 127 / 32 + 4, 16, 8.5);
      await alex.until(
        (_) => alex.decodedFrom(next).whereType<Teleport>().isNotEmpty,
      );
      final teleport = alex.decodedFrom(next).whereType<Teleport>().single;
      expect(teleport.entityId, steve.entityId);
      expect(teleport.x, 272 + 127 + 128);
      expect(teleport.y, 512);
      expect(teleport.z, 272);
      expect(alex.decodedFrom(next).whereType<RelMove>(), isEmpty);
    });
  });

  test('an out of range position is not applied or replicated', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final before = alex.frames.length;
      steve.sendPosition(8.5, -100, 8.5);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alex.frames.length, before);
      expect(endpoint.sessions.singleWhere((s) => s.name == 'Steve').y, 16);
    });
  });

  test('a ground-only change is a zero relative move', () async {
    await _with(2, (endpoint, players) async {
      final steve = players[0];
      final alex = players[1];
      final before = alex.frames.length;
      steve.sendGround(false);
      await alex.until(
        (_) => alex.decodedFrom(before).whereType<RelMove>().isNotEmpty,
      );
      final move = alex.decodedFrom(before).whereType<RelMove>().single;
      expect(move.entityId, steve.entityId);
      expect(move.dx, 0);
      expect(move.dy, 0);
      expect(move.dz, 0);
      expect(move.onGround, isFalse);
      expect(
        endpoint.sessions.singleWhere((s) => s.name == 'Steve').onGround,
        isFalse,
      );
    });
  });

  test('one encode is delivered to every other session', () async {
    await _with(3, (endpoint, players) async {
      final steve = players[0];
      final encodes = endpoint.replicationEncodes;
      final deliveries = endpoint.replicationDeliveries;
      final marks = [for (final player in players) player.frames.length];
      steve.sendPosition(8.75, 16, 8.5);
      await players[1].until(
        (_) => players[1].decodedFrom(marks[1]).whereType<RelMove>().isNotEmpty,
      );
      await players[2].until(
        (_) => players[2].decodedFrom(marks[2]).whereType<RelMove>().isNotEmpty,
      );
      expect(
        players[1].decodedFrom(marks[1]).whereType<RelMove>().single.dx,
        8,
      );
      expect(
        players[2].decodedFrom(marks[2]).whereType<RelMove>().single.dx,
        8,
      );
      expect(players[0].decodedFrom(marks[0]).whereType<RelMove>(), isEmpty);
      expect(endpoint.replicationEncodes - encodes, 1);
      expect(endpoint.replicationDeliveries - deliveries, 2);
    });
  });

  test(
    'disconnect removes the entity and the tab entry once, and reconnect does not duplicate it',
    () async {
      await _with(2, (endpoint, players) async {
        final steve = players[0];
        final alex = players[1];
        final oldId = steve.entityId;
        final uuid = steve.uuidBytes;
        await steve.close();
        await alex.until(
          (_) =>
              alex.destroysOf(oldId).isNotEmpty &&
              alex.removesOf(uuid).isNotEmpty,
        );
        await _until(() => endpoint.sessions.length == 1);
        expect(alex.destroysOf(oldId), [
          [oldId],
        ]);
        expect(alex.removesOf(uuid), hasLength(1));
        expect(endpoint.sessions.single.name, 'Alex');

        final mark = alex.frames.length;
        final again = await Probe.connect(endpoint.port);
        try {
          await again.login('Steve');
          await alex.until((_) => alex.spawnsOf(uuid, from: mark).length == 1);
          final spawn = alex.spawnsOf(uuid, from: mark).single;
          expect(spawn.entityId, isNot(oldId));
          expect(spawn.entityId, again.entityId);
          expect(alex.spawnsOf(uuid, from: mark), hasLength(1));
          expect(alex.destroysOf(oldId), [
            [oldId],
          ]);
          expect(
            alex
                .decodedFrom(mark)
                .whereType<TabAdd>()
                .where((p) => p.name == 'Steve'),
            hasLength(1),
          );
          expect(endpoint.sessions.map((s) => s.entityId).toSet(), {
            alex.entityId,
            again.entityId,
          });
        } finally {
          await again.close();
        }
      });
    },
  );

  test('visibility does not require a movement primitive listener', () async {
    var calls = 0;
    await _with(
      2,
      (endpoint, players) async {
        final steve = players[0];
        final alex = players[1];
        expect(alex.spawnsOf(steve.uuidBytes), hasLength(1));
        final before = alex.frames.length;
        steve.sendPosition(9, 16, 8.5);
        await alex.until(
          (_) => alex.decodedFrom(before).whereType<RelMove>().isNotEmpty,
        );
        expect(calls, 0);
      },
      onPrimitive: (id, _) {
        if (id == ProtocolPrimitive.position) calls++;
      },
      interestedIn: (_) => false,
    );
  });

  test('sneak and sprint are stored and replicated as metadata', () async {
    await _with(1, (endpoint, players) async {
      final steve = players.single;
      steve.sendAction(steve.entityId, 0);
      await _until(() => endpoint.sessions.single.sneaking);
      final alex = await Probe.connect(endpoint.port);
      try {
        await alex.login('Alex');
        await alex.until((_) => alex.spawnsOf(steve.uuidBytes).isNotEmpty);
        expect(alex.spawnsOf(steve.uuidBytes).single.flags, 0x02);
        final before = alex.frames.length;
        final self = steve.frames.length;
        steve.sendAction(steve.entityId, 3);
        await alex.until(
          (_) => alex.metadataOf(steve.entityId, from: before).isNotEmpty,
        );
        expect(
          alex.metadataOf(steve.entityId, from: before).single.flags,
          0x0A,
        );
        expect(
          endpoint.sessions.singleWhere((s) => s.name == 'Steve').sprinting,
          isTrue,
        );

        final stopped = alex.frames.length;
        steve.sendAction(steve.entityId, 1);
        await alex.until(
          (_) => alex.metadataOf(steve.entityId, from: stopped).isNotEmpty,
        );
        expect(
          alex.metadataOf(steve.entityId, from: stopped).single.flags,
          0x08,
        );
        final clear = alex.frames.length;
        steve.sendAction(steve.entityId, 4);
        await alex.until(
          (_) => alex.metadataOf(steve.entityId, from: clear).isNotEmpty,
        );
        expect(alex.metadataOf(steve.entityId, from: clear).single.flags, 0);
        expect(steve.metadataOf(steve.entityId, from: self), isEmpty);
      } finally {
        await alex.close();
      }
    });
  });

  test(
    'a late joiner gets the latest pose once and not the movement history',
    () async {
      await _with(2, (endpoint, players) async {
        final steve = players[0];
        final alex = players[1];
        final encodes = endpoint.replicationEncodes;
        final deliveries = endpoint.replicationDeliveries;
        for (var step = 1; step <= 30; step++) {
          steve.sendPosition(8.5 + step * 0.25, 16, 8.5);
        }
        await alex.until((_) => alex.decoded.whereType<RelMove>().length >= 30);
        expect(alex.decoded.whereType<RelMove>(), hasLength(30));
        expect(alex.decoded.whereType<Teleport>(), isEmpty);
        expect(endpoint.replicationEncodes - encodes, 30);
        expect(endpoint.replicationDeliveries - deliveries, 30);

        final bob = await Probe.connect(endpoint.port);
        try {
          await bob.login('Bob');
          await bob.until((_) => bob.spawnsOf(steve.uuidBytes).isNotEmpty);
          final spawn = bob.spawnsOf(steve.uuidBytes).single;
          expect(spawn.x, 512);
          expect(spawn.y, 512);
          expect(spawn.z, 272);
          expect(
            bob.decoded.whereType<RelMove>().where(
              (p) => p.entityId == steve.entityId,
            ),
            isEmpty,
          );
          expect(bob.decoded.whereType<Teleport>(), isEmpty);
        } finally {
          await bob.close();
        }
      });
    },
  );
}

Future<void> _with(
  int count,
  Future<void> Function(ProtocolEndpoint endpoint, List<Probe> players) body, {
  PrimitiveListener? onPrimitive,
  PrimitiveInterest? interestedIn,
}) async {
  final endpoint = ProtocolEndpoint(
    versionName: 'AyuMC 1.8.9',
    protocolVersion: 47,
    description: 'test',
    keepAliveInterval: const Duration(hours: 1),
    onPrimitive: onPrimitive,
    interestedIn: interestedIn,
  );
  await endpoint.bind(port: 0);
  final players = <Probe>[];
  try {
    const names = ['Steve', 'Alex', 'Bob'];
    for (var i = 0; i < count; i++) {
      final probe = await Probe.connect(endpoint.port);
      players.add(probe);
      await probe.login(names[i]);
    }
    for (final probe in players) {
      for (final other in players) {
        if (identical(probe, other)) continue;
        await probe.until((_) => probe.spawnsOf(other.uuidBytes).isNotEmpty);
        final listAt = probe.decoded.indexWhere(
          (p) => p is TabAdd && p.name == other.name,
        );
        final spawnAt = probe.decoded.indexWhere(
          (p) => p is Spawn && _same(p.uuid, other.uuidBytes),
        );
        expect(
          listAt,
          greaterThanOrEqualTo(0),
          reason: '${probe.name} missing tab entry for ${other.name}',
        );
        expect(
          spawnAt,
          greaterThan(listAt),
          reason: '${other.name} spawned before the player list entry',
        );
      }
    }
    await body(endpoint, players);
  } finally {
    for (final probe in players) {
      await probe.close();
    }
    await endpoint.close();
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class Probe {
  Probe._(this.socket) {
    _subscription = socket.listen((chunk) {
      _buffer.add(chunk);
      while (true) {
        final frame = _buffer.readFrame();
        if (frame == null) return;
        frames.add(frame);
      }
    }, onError: (_, _) {});
  }

  static Future<Probe> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    return Probe._(socket);
  }

  final Socket socket;
  final PacketBuffer _buffer = PacketBuffer();
  final List<Uint8List> frames = [];
  late final StreamSubscription<List<int>> _subscription;
  String name = '';
  bool _closed = false;

  Uint8List get uuidBytes => offlinePlayerUuidBytes(name);

  Future<void> login(String playerName) async {
    name = playerName;
    socket.add(_handshake());
    socket.add(encodePacket(0x00, encodeString(playerName)));
    await until((_) => frames.length >= 8 && entityId > 0);
  }

  Future<void> until(bool Function(Probe probe) ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!ready(this)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('$name timed out after ${frames.length} frames');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void sendPosition(double x, double y, double z, {bool onGround = true}) {
    socket.add(
      encodePacket(0x04, [
        ...encodeDouble(x),
        ...encodeDouble(y),
        ...encodeDouble(z),
        onGround ? 1 : 0,
      ]),
    );
  }

  void sendLook(double yaw, double pitch, {bool onGround = true}) {
    socket.add(
      encodePacket(0x05, [
        ...encodeFloat(yaw),
        ...encodeFloat(pitch),
        onGround ? 1 : 0,
      ]),
    );
  }

  void sendPositionAndLook(
    double x,
    double y,
    double z, {
    required double yaw,
    required double pitch,
    bool onGround = true,
  }) {
    socket.add(
      encodePacket(0x06, [
        ...encodeDouble(x),
        ...encodeDouble(y),
        ...encodeDouble(z),
        ...encodeFloat(yaw),
        ...encodeFloat(pitch),
        onGround ? 1 : 0,
      ]),
    );
  }

  void sendGround(bool onGround) {
    socket.add(encodePacket(0x03, [onGround ? 1 : 0]));
  }

  void sendAction(int entityId, int action) {
    socket.add(
      encodePacket(0x0B, [
        ...encodeVarInt(entityId),
        ...encodeVarInt(action),
        ...encodeVarInt(0),
      ]),
    );
  }

  int get entityId {
    for (final frame in frames) {
      if (frame.isNotEmpty && frame[0] == 0x01 && frame.length >= 5) {
        return ByteData.sublistView(frame).getInt32(1);
      }
    }
    return 0;
  }

  String get loginUuid {
    final body = PacketBuffer()..add(frames.first);
    expect(body.readVarInt(), 0x02);
    return body.readString();
  }

  List<int> get ids => [
    for (final frame in frames) (PacketBuffer()..add(frame)).readVarInt(),
  ];

  List<Inbound> get decoded => decodedFrom(0);

  List<Inbound> decodedFrom(int from) => [
    for (final frame in frames.skip(from)) _decode(frame),
  ];

  List<Spawn> spawnsOf(Uint8List uuid, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is Spawn && _same(packet.uuid, uuid)) packet,
  ];

  List<Inbound> movesOf(int entityId, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is RelMove ||
          packet is LookMove ||
          packet is Look ||
          packet is Teleport ||
          packet is HeadLook)
        if (packet.entityId == entityId) packet,
  ];

  List<Look> looksOf(int entityId, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is Look && packet.entityId == entityId) packet,
  ];

  List<HeadLook> headsOf(int entityId, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is HeadLook && packet.entityId == entityId) packet,
  ];

  List<Teleport> teleportsOf(int entityId, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is Teleport && packet.entityId == entityId) packet,
  ];

  List<List<int>> destroysOf(int entityId) => [
    for (final packet in decoded)
      if (packet is Destroy && packet.entityIds.contains(entityId))
        packet.entityIds,
  ];

  List<TabRemove> removesOf(Uint8List uuid) => [
    for (final packet in decoded)
      if (packet is TabRemove && _same(packet.uuid, uuid)) packet,
  ];

  List<Metadata> metadataOf(int entityId, {int from = 0}) => [
    for (final packet in decodedFrom(from))
      if (packet is Metadata && packet.entityId == entityId) packet,
  ];

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    socket.destroy();
  }
}

Uint8List _handshake() {
  return encodePacket(0x00, [
    ...encodeVarInt(47),
    ...encodeString('localhost'),
    ...encodeUnsignedShort(25565),
    ...encodeVarInt(2),
  ]);
}

Inbound _decode(Uint8List frame) {
  final body = PacketBuffer()..add(frame);
  final id = body.readVarInt();
  switch (id) {
    case 0x38:
      final action = body.readVarInt();
      final count = body.readVarInt();
      if (count != 1) throw StateError('player list count $count');
      final uuid = body.readBytes(16);
      if (action == 4) {
        _end(body);
        return TabRemove(uuid);
      }
      if (action != 0) throw StateError('player list action $action');
      final name = body.readString();
      if (body.readVarInt() != 0) throw StateError('unexpected properties');
      final gamemode = body.readVarInt();
      final ping = body.readVarInt();
      if (body.readBool()) throw StateError('unexpected display name');
      _end(body);
      return TabAdd(uuid, name, gamemode, ping);
    case 0x0C:
      final entityId = body.readVarInt();
      final uuid = body.readBytes(16);
      final x = body.readInt();
      final y = body.readInt();
      final z = body.readInt();
      final yaw = body.readUnsignedByte();
      final pitch = body.readUnsignedByte();
      final item = body.readShort();
      final header = body.readUnsignedByte();
      final flags = body.readUnsignedByte();
      final end = body.readUnsignedByte();
      if (header != 0x00 || end != 0x7F) {
        throw StateError('metadata $header $flags $end');
      }
      _end(body);
      return Spawn(entityId, uuid, x, y, z, yaw, pitch, item, flags);
    case 0x15:
      return RelMove(
        body.readVarInt(),
        _signed(body),
        _signed(body),
        _signed(body),
        _ground(body),
      );
    case 0x16:
      final entityId = body.readVarInt();
      final yaw = body.readUnsignedByte();
      final pitch = body.readUnsignedByte();
      return Look(entityId, yaw, pitch, _ground(body));
    case 0x17:
      final entityId = body.readVarInt();
      final dx = _signed(body);
      final dy = _signed(body);
      final dz = _signed(body);
      final yaw = body.readUnsignedByte();
      final pitch = body.readUnsignedByte();
      return LookMove(entityId, dx, dy, dz, yaw, pitch, _ground(body));
    case 0x18:
      final entityId = body.readVarInt();
      final x = body.readInt();
      final y = body.readInt();
      final z = body.readInt();
      final yaw = body.readUnsignedByte();
      final pitch = body.readUnsignedByte();
      return Teleport(entityId, x, y, z, yaw, pitch, _ground(body));
    case 0x19:
      final entityId = body.readVarInt();
      final yaw = body.readUnsignedByte();
      _end(body);
      return HeadLook(entityId, yaw);
    case 0x13:
      final count = body.readVarInt();
      final ids = [for (var i = 0; i < count; i++) body.readVarInt()];
      _end(body);
      return Destroy(ids);
    case 0x1C:
      final entityId = body.readVarInt();
      final header = body.readUnsignedByte();
      final flags = body.readUnsignedByte();
      final end = body.readUnsignedByte();
      if (header != 0x00 || end != 0x7F) {
        throw StateError('metadata update $header $flags $end');
      }
      _end(body);
      return Metadata(entityId, flags);
    default:
      return Raw(id);
  }
}

int _signed(PacketBuffer body) {
  final value = body.readUnsignedByte();
  return value > 127 ? value - 256 : value;
}

bool _ground(PacketBuffer body) {
  final value = body.readBool();
  _end(body);
  return value;
}

void _end(PacketBuffer body) {
  if (body.length != 0) throw StateError('${body.length} trailing bytes');
}

sealed class Inbound {
  int get entityId => -1;
}

final class Raw extends Inbound {
  Raw(this.id);
  final int id;
}

final class TabAdd extends Inbound {
  TabAdd(this.uuid, this.name, this.gamemode, this.ping);
  final Uint8List uuid;
  final String name;
  final int gamemode;
  final int ping;
}

final class TabRemove extends Inbound {
  TabRemove(this.uuid);
  final Uint8List uuid;
}

final class Spawn extends Inbound {
  Spawn(
    this.entityId,
    this.uuid,
    this.x,
    this.y,
    this.z,
    this.yaw,
    this.pitch,
    this.item,
    this.flags,
  );
  @override
  final int entityId;
  final Uint8List uuid;
  final int x;
  final int y;
  final int z;
  final int yaw;
  final int pitch;
  final int item;
  final int flags;
}

final class RelMove extends Inbound {
  RelMove(this.entityId, this.dx, this.dy, this.dz, this.onGround);
  @override
  final int entityId;
  final int dx;
  final int dy;
  final int dz;
  final bool onGround;
}

final class Look extends Inbound {
  Look(this.entityId, this.yaw, this.pitch, this.onGround);
  @override
  final int entityId;
  final int yaw;
  final int pitch;
  final bool onGround;
}

final class LookMove extends Inbound {
  LookMove(
    this.entityId,
    this.dx,
    this.dy,
    this.dz,
    this.yaw,
    this.pitch,
    this.onGround,
  );
  @override
  final int entityId;
  final int dx;
  final int dy;
  final int dz;
  final int yaw;
  final int pitch;
  final bool onGround;
}

final class Teleport extends Inbound {
  Teleport(
    this.entityId,
    this.x,
    this.y,
    this.z,
    this.yaw,
    this.pitch,
    this.onGround,
  );
  @override
  final int entityId;
  final int x;
  final int y;
  final int z;
  final int yaw;
  final int pitch;
  final bool onGround;
}

final class HeadLook extends Inbound {
  HeadLook(this.entityId, this.yaw);
  @override
  final int entityId;
  final int yaw;
}

final class Destroy extends Inbound {
  Destroy(this.entityIds);
  final List<int> entityIds;
}

final class Metadata extends Inbound {
  Metadata(this.entityId, this.flags);
  @override
  final int entityId;
  final int flags;
}
