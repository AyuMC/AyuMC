// Protocol-47 client that decodes Map Chunk Data. Not a Minecraft binary.
// dart run benchmark/chunk_client.dart --port 25565 --clients 1 --view 4
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';

Future<void> main(List<String> args) async {
  final port = _flag(args, '--port', 25565);
  final clients = _flag(args, '--clients', 1);
  final view = _flag(args, '--view', 2);
  final seconds = _flag(args, '--seconds', 2);
  final move = args.contains('--move');
  if (port < 1 || clients < 1) {
    stderr.writeln('port and clients must be positive');
    exitCode = 1;
    return;
  }
  final sims = <_Sim>[];
  final started = Stopwatch()..start();
  try {
    for (var i = 0; i < clients; i++) {
      sims.add(await _Sim.login(port, 'c$i', view));
    }
    if (move) {
      for (final sim in sims) {
        sim.walk();
      }
    }
    await Future<void>.delayed(Duration(seconds: seconds));
  } finally {
    for (final sim in sims) {
      await sim.close();
    }
  }
  started.stop();
  var decoded = 0;
  var handed = 0;
  var standingFirst = 0;
  for (final sim in sims) {
    decoded += sim.decodedColumns;
    handed += sim.frames;
    if (sim.standingBeforeLook) standingFirst++;
  }
  stdout.writeln(
    'chunk client: $clients clients, ${started.elapsedMilliseconds} ms, '
    'decoded $decoded columns, frames $handed, '
    'standing-before-0x08 $standingFirst/$clients',
  );
}

int _flag(List<String> args, String name, int fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return int.parse(args[index + 1]);
}

final class _Sim {
  _Sim(this.socket, this.name) {
    subscription = socket.listen((chunk) {
      buffer.add(chunk);
      while (true) {
        final frame = buffer.readFrame(maxFrameBytes: 256 * 1024);
        if (frame == null) return;
        frames++;
        _take(frame);
      }
    }, onError: (_, _) {});
  }

  static Future<_Sim> login(int port, String name, int view) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final sim = _Sim(socket, name);
    socket.add(
      encodePacket(0x00, [
        ...encodeVarInt(47),
        ...encodeString('localhost'),
        ...encodeUnsignedShort(25565),
        ...encodeVarInt(2),
      ]),
    );
    socket.add(encodePacket(0x00, encodeString(name)));
    await sim.ready.future.timeout(const Duration(seconds: 10));
    socket.add(
      encodePacket(0x15, [...encodeString('en_US'), view, 0, 1, 0x7F]),
    );
    return sim;
  }

  final Socket socket;
  final String name;
  final PacketBuffer buffer = PacketBuffer();
  final Completer<void> ready = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  int frames = 0;
  int decodedColumns = 0;
  bool seenChunk = false;
  bool seenLook = false;
  bool standingBeforeLook = false;

  void _take(Uint8List frame) {
    final id = frame.isEmpty ? -1 : frame[0];
    if (id == 0x21) {
      final decoded = decodeChunkColumn(frame);
      if (decoded != null) {
        decodedColumns++;
        seenChunk = true;
        if (!seenLook && decoded.chunkX == 0 && decoded.chunkZ == 0) {
          standingBeforeLook = true;
        }
      }
    } else if (id == 0x08) {
      seenLook = true;
      if (!ready.isCompleted) ready.complete();
    }
  }

  void walk() {
    socket.add(
      encodePacket(0x04, [
        ...encodeDouble(40.5),
        ...encodeDouble(16),
        ...encodeDouble(8.5),
        1,
      ]),
    );
  }

  Future<void> close() async {
    await subscription.cancel();
    socket.destroy();
  }
}
