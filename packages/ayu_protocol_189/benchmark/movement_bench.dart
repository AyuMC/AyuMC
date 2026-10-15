// Protocol-47 movement fan-out with the server in its own process.
// CPU and RSS below are that process only. This is not a production capacity
// result: every client can see every other client, so delivery is O(N²).
//
// From packages/ayu_protocol_189:
// dart run benchmark/movement_bench.dart --clients 10 --seconds 2 --hz 20
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';

Future<void> main(List<String> args) async {
  final clients = _flag(args, '--clients', 1);
  final seconds = _flag(args, '--seconds', 2);
  final hz = _flag(args, '--hz', 20);
  final warmupTicks = _flag(args, '--warmup-ticks', 5);
  final spread = _flag(args, '--spread', 0);
  final updateMs = _flag(args, '--update-ms', 0);
  final visibility = _text(args, '--visibility', 'spatial');
  if (clients < 1 || seconds < 1 || hz < 1) {
    stderr.writeln('clients, seconds, and hz must be positive');
    exitCode = 1;
    return;
  }

  final root = await Directory.systemTemp.createTemp('ayu-move-server-');
  final separator = Platform.pathSeparator;
  await Directory('${root.path}${separator}config').create();
  await File('${root.path}${separator}config${separator}server.json').writeAsString(
    '{"profile":"AyuMC-1.8.9-release","port":0,"visibility":"$visibility","viewChunks":10,"entityUpdateMillis":$updateMs}',
  );
  final core = Directory('${Directory.current.path}$separator..${separator}ayu_core');
  final server = await Process.start(Platform.resolvedExecutable, [
    'run',
    'benchmark/movement_server.dart',
    root.path,
  ], workingDirectory: core.path);
  final ayu = _LineQueue();
  server.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('AYU ')) ayu.add(line);
  });
  server.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    stderr.writeln('server: $line');
  });
  final readyLine = await ayu.next(const Duration(seconds: 30));
  final ready = _fields(readyLine);
  final port = int.parse(ready['port']!);
  final serverPid = int.parse(ready['pid']!);
  final sims = <_Sim>[];
  final login = Stopwatch()..start();
  try {
    for (var start = 0; start < clients; start += 20) {
      final count = clients - start < 20 ? clients - start : 20;
      sims.addAll(
        await Future.wait(List.generate(count, (offset) => _Sim.login(port, start + offset))),
      );
    }
    login.stop();
    final afterLogin = await _stats(server.stdin, ayu);

    final period = Duration(microseconds: (1000000 / hz).round());
    if (spread > 0) {
      for (final sim in sims) {
        sim.sendPosition(8.5 + sim.index * spread);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _drive(sims, warmupTicks, period, spread);
    final afterWarmup = await _stats(server.stdin, ayu);

    final cpuBefore = await _sample(serverPid);
    final steady = Stopwatch()..start();
    final lateTicks = await _drive(sims, hz * seconds, period, spread);
    steady.stop();
    final afterSteady = await _stats(server.stdin, ayu);
    final cpuAfter = await _sample(serverPid);
    final inbound = sims.fold<int>(0, (sum, sim) => sum + sim.inboundBytes);
    final decoded = sims.fold<int>(0, (sum, sim) => sum + sim.decodedEntities);

    final accepted = afterSteady['accepted']! - afterWarmup['accepted']!;
    final encodes = afterSteady['encodes']! - afterWarmup['encodes']!;
    final deliveries = afterSteady['deliveries']! - afterWarmup['deliveries']!;
    final bytes = afterSteady['bytes']! - afterWarmup['bytes']!;
    stdout.writeln(
      'measurement=server_process_only visibility=$visibility spread=$spread update_ms=$updateMs subscribers=none',
    );
    stdout.writeln('clients=$clients hz=$hz seconds=$seconds server_pid=$serverPid');
    stdout.writeln('login_ms=${login.elapsedMilliseconds} steady_ms=${steady.elapsedMilliseconds}');
    stdout.writeln('warmup_ticks=$warmupTicks late_ticks=$lateTicks');
    stdout.writeln(
      'steady_accepted=$accepted encodes=$encodes deliveries=$deliveries socket_add_bytes=$bytes',
    );
    stdout.writeln(
      'steady_spawns=${afterSteady['spawns']! - afterWarmup['spawns']!} '
      'destroys=${afterSteady['destroys']! - afterWarmup['destroys']!} '
      'gap_max_micros=${afterSteady['gapMaxMicros']} delay_max_micros=${afterSteady['delayMaxMicros']}',
    );
    stdout.writeln('client_decoded_entity_packets=$decoded');
    stdout.writeln('login_accepted=${afterLogin['accepted']}');
    final drain = Stopwatch()..start();
    for (final sim in sims) {
      await sim.close();
    }
    sims.clear();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    drain.stop();
    stdout.writeln('drain_ms=${drain.elapsedMilliseconds}');
    stdout.writeln('client_inbound_bytes_at_steady_end=$inbound');
    stdout.writeln(
      'server_rss_before=${cpuBefore?.rss ?? 'unavailable'} server_rss_after=${cpuAfter?.rss ?? 'unavailable'}',
    );
    final cpu = cpuBefore == null || cpuAfter == null ? null : cpuAfter.cpu - cpuBefore.cpu;
    stdout.writeln(cpu == null ? 'server_cpu_seconds=unavailable' : 'server_cpu_seconds=${cpu.toStringAsFixed(3)}');
    stdout.writeln('socket_add_bytes are handed to the socket, not a count of bytes the clients have read');
    stdout.writeln('fan-out grows with eligible viewers; this is not a production player-capacity result');
    if (accepted < clients * hz * seconds) exitCode = 1;
  } finally {
    for (final sim in sims) {
      await sim.close();
    }
    server.stdin.writeln('stop');
    await server.exitCode.timeout(const Duration(seconds: 20));
    if (await root.exists()) await root.delete(recursive: true);
  }
}

String _text(List<String> args, String name, String fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

Future<int> _drive(List<_Sim> sims, int ticks, Duration period, int spread) async {
  final started = DateTime.now();
  var late = 0;
  for (var tick = 1; tick <= ticks; tick++) {
    for (final sim in sims) {
      sim.sendPosition(8.5 + sim.index * spread + tick * 0.25);
    }
    final wait = started.add(period * tick).difference(DateTime.now());
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    } else {
      late++;
    }
  }
  return late;
}

Future<Map<String, int>> _stats(IOSink stdin, _LineQueue lines) async {
  stdin.writeln('stats');
  final line = await lines.next(const Duration(seconds: 5));
  final json = jsonDecode(line.substring('AYU stats '.length)) as Map<String, Object?>;
  return {
    for (final entry in json.entries) entry.key: entry.value as int,
  };
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
  _Sim(this.socket, this.name, this.index) {
    final buffer = PacketBuffer();
    subscription = socket.listen((chunk) {
      inboundBytes += chunk.length;
      buffer.add(chunk);
      while (true) {
        final frame = buffer.readFrame();
        if (frame == null) return;
        frames++;
        if (frame.isNotEmpty && _entityPacket(frame[0])) decodedEntities++;
        if (frames >= 8 && !ready.isCompleted) ready.complete();
      }
    }, onError: (_, _) {});
  }

  static bool _entityPacket(int id) =>
      id == 0x0C || id == 0x13 || id == 0x15 || id == 0x16 || id == 0x17 || id == 0x18 || id == 0x19 || id == 0x1C;

  static Future<_Sim> login(int port, int index) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final sim = _Sim(socket, 'p${index.toString().padLeft(3, '0')}', index);
    socket.add(encodePacket(0x00, [
      ...encodeVarInt(47),
      ...encodeString('localhost'),
      ...encodeUnsignedShort(25565),
      ...encodeVarInt(2),
    ]));
    socket.add(encodePacket(0x00, encodeString(sim.name)));
    await sim.ready.future.timeout(const Duration(seconds: 5));
    return sim;
  }

  final Socket socket;
  final String name;
  final int index;
  final Completer<void> ready = Completer<void>();
  int inboundBytes = 0;
  int frames = 0;
  int decodedEntities = 0;
  late final StreamSubscription<List<int>> subscription;

  void sendPosition(double x) {
    socket.add(encodePacket(0x04, [
      ...encodeDouble(x),
      ...encodeDouble(16),
      ...encodeDouble(8.5),
      1,
    ]));
  }

  Future<void> close() async {
    await subscription.cancel();
    await socket.close();
  }
}
