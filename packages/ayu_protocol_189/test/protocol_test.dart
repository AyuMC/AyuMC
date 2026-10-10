import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:test/test.dart';

void main() {
  test('VarInt and packet framing round-trip', () {
    for (final value in [0, 1, 127, 128, 255, 25565, 1 << 21]) {
      final buffer = PacketBuffer()..add(encodeVarInt(value));
      expect(buffer.readVarInt(), value);
    }
    final packet = encodePacket(0x00, encodeString('hi'));
    final frames = PacketBuffer()..add(packet.sublist(0, 1))..add(packet.sublist(1));
    final frame = frames.readFrame()!;
    final body = PacketBuffer()..add(frame);
    expect(body.readVarInt(), 0x00);
    expect(body.readString(), 'hi');
  });

  test('a truncated frame is not consumed and a huge length is rejected', () {
    final buffer = PacketBuffer()..add(encodeVarInt(10));
    expect(buffer.readFrame(), isNull);
    expect(buffer.length, encodeVarInt(10).length);
    expect(() => (PacketBuffer()..add(encodeVarInt(1 << 21))).readFrame(maxFrameBytes: 32), throwsA(isA<PacketFormatException>()));
  });

  test('status request and ping answer protocol 47', () async {
    final endpoint = ProtocolEndpoint(versionName: 'AyuMC 1.8.9', protocolVersion: 47, description: 'test');
    await endpoint.bind(port: 0);
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, endpoint.port);
      addTearDown(socket.close);
      socket.add(_handshake(nextState: 1));
      socket.add(encodePacket(0x00));
      socket.add(encodePacket(0x01, encodeLong(0x1122334455667788)));
      final packets = await _readPackets(socket, 2);
      final status = PacketBuffer()..add(packets[0]);
      expect(status.readVarInt(), 0x00);
      final json = jsonDecode(status.readString()) as Map<String, Object?>;
      expect((json['version'] as Map)['protocol'], 47);
      expect((json['description'] as Map)['text'], 'test');
      final pong = PacketBuffer()..add(packets[1]);
      expect(pong.readVarInt(), 0x01);
      expect(pong.readLong(), 0x1122334455667788);
    } finally {
      await endpoint.close();
    }
  });

  test('login start emits a primitive and does not enter play', () async {
    final seen = <String, Map<String, Object?>>{};
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'test',
      onPrimitive: (id, data) => seen[id] = data,
    );
    await endpoint.bind(port: 0);
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, endpoint.port);
      socket.add(_handshake(nextState: 2));
      socket.add(encodePacket(0x00, encodeString('Steve')));
      final packets = await _readPackets(socket, 1);
      final disconnect = PacketBuffer()..add(packets.single);
      expect(disconnect.readVarInt(), 0x00);
      expect(jsonDecode(disconnect.readString()), {'text': 'AyuMC has no play session yet'});
      expect(seen[ProtocolPrimitive.handshake]?['nextState'], 2);
      expect(seen[ProtocolPrimitive.login]?['name'], 'Steve');
      expect(seen[ProtocolPrimitive.handshake]?['protocol'], 47);
      await socket.close();
    } finally {
      await endpoint.close();
    }
  });

  test('a different protocol version is rejected without a status response', () async {
    final endpoint = ProtocolEndpoint(versionName: 'AyuMC 1.8.9', protocolVersion: 47, description: 'test');
    await endpoint.bind(port: 0);
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, endpoint.port);
      final closed = socket.listen((_) {}).asFuture<void>();
      socket.add(_handshake(protocol: 340, nextState: 1));
      socket.add(encodePacket(0x00));
      await closed.timeout(const Duration(seconds: 2));
    } finally {
      await endpoint.close();
    }
  });
}

Uint8List _handshake({int protocol = 47, int nextState = 1}) {
  final payload = <int>[
    ...encodeVarInt(protocol),
    ...encodeString('localhost'),
    ...encodeUnsignedShort(25565),
    ...encodeVarInt(nextState),
  ];
  return encodePacket(0x00, payload);
}

Future<List<Uint8List>> _readPackets(Socket socket, int count) async {
  final buffer = PacketBuffer();
  final packets = <Uint8List>[];
  final done = Completer<void>();
  final subscription = socket.listen((chunk) {
    buffer.add(chunk);
    while (packets.length < count) {
      final frame = buffer.readFrame();
      if (frame == null) return;
      packets.add(frame);
    }
    if (!done.isCompleted) done.complete();
  }, onDone: () {
    if (!done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(seconds: 2));
  await subscription.cancel();
  expect(packets, hasLength(count));
  return packets;
}
