// Stage 3 of the load ladder: offline login into the play state, one position, disconnect.
// Not a 5,000-player result. Run: dart run benchmark/login_bench.dart 200
import 'dart:io';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 100 : int.parse(args.first);
  final endpoint = ProtocolEndpoint(
    versionName: 'AyuMC 1.8.9',
    protocolVersion: 47,
    description: 'bench',
    keepAliveInterval: const Duration(hours: 1),
  );
  await endpoint.bind(port: 0);
  final started = DateTime.now();
  var ok = 0;
  var failed = 0;
  const width = 50;
  for (var offset = 0; offset < count; offset += width) {
    final batch = count - offset < width ? count - offset : width;
    final results = await Future.wait(List.generate(batch, (_) => _one(endpoint.port)));
    for (final success in results) {
      if (success) {
        ok++;
      } else {
        failed++;
      }
    }
  }
  final elapsed = DateTime.now().difference(started);
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (endpoint.sessions.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  stdout.writeln('offline play logins: $ok ok, $failed failed, ${elapsed.inMilliseconds} ms, '
      '${(ok / elapsed.inMilliseconds * 1000).toStringAsFixed(1)} sessions/s');
  stdout.writeln('open sessions after clients disconnected: ${endpoint.sessions.length}');
  await endpoint.close();
}

Future<bool> _one(int port) async {
  try {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final payload = <int>[
      ...encodeVarInt(47),
      ...encodeString('localhost'),
      ...encodeUnsignedShort(25565),
      ...encodeVarInt(2),
    ];
    socket.add(encodePacket(0x00, payload));
    socket.add(encodePacket(0x00, encodeString('Steve')));
    final buffer = PacketBuffer();
    var frames = 0;
    await socket.timeout(const Duration(seconds: 3)).forEach((chunk) {
      buffer.add(chunk);
      while (buffer.readFrame() != null) {
        frames++;
      }
      if (frames >= 8) socket.destroy();
    });
    return frames >= 8;
  } on Object {
    return false;
  }
}
