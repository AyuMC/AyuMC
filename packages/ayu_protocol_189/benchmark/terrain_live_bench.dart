// Live engine responsiveness with TerrainGeneratorV1 and a decoding client.
// From packages/ayu_protocol_189:
// dart run benchmark/terrain_live_bench.dart --clients 1 --seconds 2
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';

Future<void> main(List<String> args) async {
  final clients = _flag(args, '--clients', 1);
  final seconds = _flag(args, '--seconds', 2);
  if (clients < 1 || seconds < 1) {
    stderr.writeln('clients and seconds must be positive');
    exitCode = 1;
    return;
  }
  final modes = <String, String>{
    'inline': '{"workers":0}',
    'workers=1': '{"workers":1}',
    'automatic': '{}',
  };
  for (final entry in modes.entries) {
    stdout.writeln('');
    stdout.writeln('mode=${entry.key} clients=$clients seconds=$seconds');
    await _mode(entry.key, entry.value, clients, seconds);
  }
}

Future<void> _mode(
  String name,
  String chunksJson,
  int clients,
  int seconds,
) async {
  final root = await Directory.systemTemp.createTemp('ayu-terrain-live-');
  final separator = Platform.pathSeparator;
  await Directory('${root.path}${separator}config').create();
  await File('${root.path}${separator}config${separator}server.json').writeAsString(
    '{"profile":"AyuMC-1.8.9-release","port":0,"viewChunks":2,'
    '"entityUpdateMillis":50,"world":{"seed":"42"},"chunks":$chunksJson}',
  );
  final core = Directory('${Directory.current.path}$separator..${separator}ayu_core');
  final server = await Process.start(Platform.resolvedExecutable, [
    'run',
    'benchmark/chunk_server.dart',
    root.path,
  ], workingDirectory: core.path);
  final ayu = _LineQueue();
  server.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('AYU ')) ayu.add(line);
    if (line.contains('Chunk workers:')) stdout.writeln(line);
  });
  server.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    stderr.writeln('server: $line');
  });
  try {
    final readyLine = await ayu.next(const Duration(seconds: 90));
    final ready = _fields(readyLine);
    final port = int.parse(ready['port']!);
    final serverPid = int.parse(ready['pid']!);
    final sims = <_Sim>[];
    final login = Stopwatch()..start();
    for (var i = 0; i < clients; i++) {
      sims.add(await _Sim.login(port, 'c$i'));
    }
    login.stop();
    final spawnMs = sims.map((s) => s.spawnMs).fold<int>(0, (a, b) => a > b ? a : b);
    stdout.writeln('login_ms=${login.elapsedMilliseconds} spawn_chunk_ms=$spawnMs');
    stdout.writeln('standing_before_0x08=${sims.where((s) => s.standingBeforeLook).length}/$clients');
    final afterLogin = await _stats(server.stdin, ayu);
    final cpuBefore = await _sample(serverPid);
    final move = Stopwatch()..start();
    for (final sim in sims) {
      sim.walk();
    }
    await Future<void>.delayed(Duration(seconds: seconds));
    move.stop();
    final afterSteady = await _stats(server.stdin, ayu);
    final cpuAfter = await _sample(serverPid);
    var decoded = 0;
    var inbound = 0;
    for (final sim in sims) {
      decoded += sim.decodedColumns;
      inbound += sim.inboundBytes;
    }
    stdout.writeln(
      'steady_ms=${move.elapsedMilliseconds} '
      'client_decoded_0x21=$decoded client_inbound_bytes=$inbound',
    );
    stdout.writeln(
      'server_chunkDeliveries=${afterSteady['chunkDeliveries']} '
      'chunkBytes=${afterSteady['chunkBytes']} '
      'generates=${afterSteady['chunkGenerates']} '
      'dedup=${afterSteady['chunkDedup']} '
      'probeLateMicros=${afterSteady['chunkProbeLateMicros']} '
      'rss=${afterSteady['rss']}',
    );
    stdout.writeln(
      'login_generates=${afterLogin['chunkGenerates']} '
      'login_deliveries=${afterLogin['chunkDeliveries']}',
    );
    stdout.writeln(
      'server_rss_before=${cpuBefore?.rss ?? 'unavailable'} '
      'server_rss_after=${cpuAfter?.rss ?? 'unavailable'}',
    );
    final cpu = cpuBefore == null || cpuAfter == null
        ? null
        : cpuAfter.cpu - cpuBefore.cpu;
    stdout.writeln(
      cpu == null
          ? 'server_cpu_seconds=unavailable'
          : 'server_cpu_seconds=${cpu.toStringAsFixed(3)}',
    );
    stdout.writeln(
      'chunkBytes are socket writes; client_decoded_0x21 is frames the simulator unpacked',
    );
    for (final sim in sims) {
      await sim.close();
    }
    server.stdin.writeln('stop');
    await server.exitCode.timeout(const Duration(seconds: 20));
  } catch (error, stack) {
    stderr.writeln('$name failed: $error\n$stack');
    server.kill();
    exitCode = 1;
  } finally {
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // Windows can keep a region handle briefly after stop.
      }
    }
  }
}

Future<Map<String, Object?>> _stats(IOSink stdin, _LineQueue lines) async {
  stdin.writeln('stats');
  final line = await lines.next(const Duration(seconds: 10));
  return jsonDecode(line.substring('AYU stats '.length)) as Map<String, Object?>;
}

final class _LineQueue {
  final List<String> _ready = [];
  final List<Completer<String>> _waiters = [];

  void add(String line) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(line);
    } else {
      _ready.add(line);
    }
  }

  Future<String> next(Duration timeout) {
    if (_ready.isNotEmpty) return Future<String>.value(_ready.removeAt(0));
    final waiter = Completer<String>();
    _waiters.add(waiter);
    return waiter.future.timeout(timeout);
  }
}

Map<String, String> _fields(String line) {
  final fields = <String, String>{};
  for (final part in line.split(' ').skip(2)) {
    final split = part.split('=');
    if (split.length == 2) fields[split[0]] = split[1];
  }
  return fields;
}

int _flag(List<String> args, String name, int fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return int.parse(args[index + 1]);
}

Future<({double cpu, int rss})?> _sample(int pid) async {
  if (!Platform.isWindows) return null;
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '(Get-Process -Id $pid | Select-Object CPU,WorkingSet64 | ConvertTo-Json -Compress)',
  ]);
  if (result.exitCode != 0) return null;
  final decoded = jsonDecode('${result.stdout}'.trim());
  if (decoded is! Map) return null;
  final cpu = decoded['CPU'];
  final rss = decoded['WorkingSet64'];
  if (cpu is! num || rss is! int) return null;
  return (cpu: cpu.toDouble(), rss: rss);
}

final class _Sim {
  _Sim(this.socket, this.name) {
    started = Stopwatch()..start();
    subscription = socket.listen((chunk) {
      inboundBytes += chunk.length;
      buffer.add(chunk);
      while (true) {
        final frame = buffer.readFrame(maxFrameBytes: 256 * 1024);
        if (frame == null) return;
        frames++;
        _take(frame);
      }
    }, onError: (_, _) {});
  }

  static Future<_Sim> login(int port, String name) async {
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
    await sim.ready.future.timeout(const Duration(seconds: 30));
    socket.add(
      encodePacket(0x15, [...encodeString('en_US'), 2, 0, 1, 0x7F]),
    );
    return sim;
  }

  final Socket socket;
  final String name;
  final PacketBuffer buffer = PacketBuffer();
  final Completer<void> ready = Completer<void>();
  late final Stopwatch started;
  late final StreamSubscription<Uint8List> subscription;
  double spawnY = 64;
  int spawnMs = 0;
  int inboundBytes = 0;
  int frames = 0;
  int decodedColumns = 0;
  bool seenLook = false;
  bool standingBeforeLook = false;

  void _take(Uint8List frame) {
    final id = frame.isEmpty ? -1 : frame[0];
    if (id == 0x21) {
      final decoded = decodeChunkColumn(frame);
      if (decoded != null && decoded.primaryBitmask != 0) {
        decodedColumns++;
        if (!seenLook) standingBeforeLook = true;
      }
    } else if (id == 0x08) {
      seenLook = true;
      spawnMs = started.elapsedMilliseconds;
      final body = PacketBuffer()..add(frame);
      body.readVarInt();
      body.readDouble();
      spawnY = body.readDouble();
      if (!ready.isCompleted) ready.complete();
    }
  }

  void walk() {
    socket.add(
      encodePacket(0x04, [
        ...encodeDouble(40.5),
        ...encodeDouble(spawnY),
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
