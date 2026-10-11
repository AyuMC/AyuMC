// Synthetic protocol-47 movement fan-out. Not a production capacity result.
// Every simulated client can see every other client. Cost grows with that
// audience. The core stays on one isolate; this does not start worker processes.
//
// dart run benchmark/movement_bench.dart --clients 10 --seconds 2 --hz 20 --events none
// --events none      replication only; position primitives are not built
// --events ignored   a listener is installed but the demand gate skips it
// --events observed  the listener runs in this process; this is not worker IPC
import 'dart:async';
import 'dart:io';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';

Future<void> main(List<String> args) async {
  final clients = _flag(args, '--clients', 1);
  final seconds = _flag(args, '--seconds', 2);
  final hz = _flag(args, '--hz', 20);
  final events = _text(args, '--events', 'none');
  if (clients < 1 || seconds < 1 || hz < 1) {
    stderr.writeln('clients, seconds, and hz must be positive');
    exitCode = 1;
    return;
  }
  if (events != 'none' && events != 'ignored' && events != 'observed') {
    stderr.writeln('--events must be none, ignored, or observed');
    exitCode = 1;
    return;
  }

  var callbacks = 0;
  final endpoint = ProtocolEndpoint(
    versionName: 'AyuMC 1.8.9',
    protocolVersion: 47,
    description: 'movement-bench',
    keepAliveInterval: const Duration(hours: 1),
    onPrimitive: events == 'none'
        ? null
        : (id, _) {
            if (id == ProtocolPrimitive.position) callbacks++;
          },
    interestedIn: switch (events) {
      'ignored' => (_) => false,
      'observed' => (id) => id == ProtocolPrimitive.position,
      _ => null,
    },
  );
  await endpoint.bind(port: 0);
  final sims = <_Sim>[];
  final login = Stopwatch()..start();
  try {
    for (var start = 0; start < clients; start += 20) {
      final count = clients - start < 20 ? clients - start : 20;
      sims.addAll(
        await Future.wait(
          List.generate(
            count,
            (offset) => _Sim.login(endpoint.port, start + offset),
          ),
        ),
      );
    }
    login.stop();
    final loginEncodes = endpoint.replicationEncodes;
    final loginDeliveries = endpoint.replicationDeliveries;
    final loginBytes = endpoint.replicationBytes;

    final ticks = hz * seconds;
    final period = Duration(microseconds: (1000000 / hz).round());
    final cpuBefore = await _cpuSeconds();
    final rssBefore = ProcessInfo.currentRss;
    final movement = Stopwatch()..start();
    final started = DateTime.now();
    var lateTicks = 0;
    for (var tick = 1; tick <= ticks; tick++) {
      final x = 8.5 + tick * 0.25;
      for (final sim in sims) {
        sim.sendPosition(x);
      }
      final next = started.add(period * tick);
      final wait = next.difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      } else {
        lateTicks++;
      }
    }
    movement.stop();
    final expected = clients * ticks;
    final drain = Stopwatch()..start();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (endpoint.acceptedMovementPackets < expected &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    drain.stop();
    final rssAfter = ProcessInfo.currentRss;
    final cpuAfter = await _cpuSeconds();
    final inbound = sims.fold<int>(0, (sum, sim) => sum + sim.inboundBytes);
    final cpu = cpuBefore == null || cpuAfter == null
        ? null
        : cpuAfter - cpuBefore;

    stdout.writeln('mode=$events clients=$clients hz=$hz seconds=$seconds');
    stdout.writeln('audience=all-to-all isolate=single worker_ipc=no');
    stdout.writeln(
      'login_ms=${login.elapsedMilliseconds} movement_window_ms=${movement.elapsedMilliseconds} drain_ms=${drain.elapsedMilliseconds}',
    );
    stdout.writeln(
      'accepted=${endpoint.acceptedMovementPackets} expected=$expected late_ticks=$lateTicks',
    );
    stdout.writeln(
      'login_replication_encodes=$loginEncodes deliveries=$loginDeliveries bytes=$loginBytes',
    );
    stdout.writeln(
      'movement_replication_encodes=${endpoint.replicationEncodes - loginEncodes} '
      'deliveries=${endpoint.replicationDeliveries - loginDeliveries} '
      'bytes=${endpoint.replicationBytes - loginBytes}',
    );
    stdout.writeln(
      'client_inbound_bytes=$inbound position_callbacks=$callbacks',
    );
    stdout.writeln('rss_before_bytes=$rssBefore rss_after_bytes=$rssAfter');
    stdout.writeln(
      cpu == null
          ? 'cpu_seconds=unavailable'
          : 'cpu_seconds=${cpu.toStringAsFixed(3)}',
    );
    stdout.writeln('keep_alives=disabled_for_this_window');
    stdout.writeln(
      'fan-out grows with eligible viewers; this is not a production player-capacity result',
    );
    if (endpoint.acceptedMovementPackets < expected) exitCode = 1;
  } finally {
    await endpoint.close();
    for (final sim in sims) {
      await sim.close();
    }
  }
}

int _flag(List<String> args, String name, int fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return int.parse(args[index + 1]);
}

String _text(List<String> args, String name, String fallback) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

Future<double?> _cpuSeconds() async {
  if (!Platform.isWindows) return null;
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '(Get-Process -Id $pid).CPU',
  ]);
  if (result.exitCode != 0) return null;
  return double.tryParse('${result.stdout}'.trim());
}

final class _Sim {
  _Sim(this.socket, this.name) {
    final buffer = PacketBuffer();
    var frames = 0;
    _subscription = socket.listen((chunk) {
      inboundBytes += chunk.length;
      if (frames >= 8) return;
      buffer.add(chunk);
      while (frames < 8) {
        if (buffer.readFrame() == null) return;
        frames++;
      }
      if (!ready.isCompleted) ready.complete();
    }, onError: (_, _) {});
  }

  static Future<_Sim> login(int port, int index) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final sim = _Sim(socket, 'p${index.toString().padLeft(3, '0')}');
    socket.add(
      encodePacket(0x00, [
        ...encodeVarInt(47),
        ...encodeString('localhost'),
        ...encodeUnsignedShort(25565),
        ...encodeVarInt(2),
      ]),
    );
    socket.add(encodePacket(0x00, encodeString(sim.name)));
    await sim.ready.future.timeout(const Duration(seconds: 5));
    return sim;
  }

  final Socket socket;
  final String name;
  final Completer<void> ready = Completer<void>();
  int inboundBytes = 0;
  late final StreamSubscription<List<int>> _subscription;

  void sendPosition(double x) {
    socket.add(
      encodePacket(0x04, [
        ...encodeDouble(x),
        ...encodeDouble(16),
        ...encodeDouble(8.5),
        1,
      ]),
    );
  }

  Future<void> close() async {
    await _subscription.cancel();
    socket.destroy();
  }
}
