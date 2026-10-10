// Measures the plugin platform with a real `.ayu` under dartaotruntime.
//
//   dart run benchmark/plugin_bench.dart [--package <file.ayu>] [--plugins N]
//
// Default package: the example plugin built by `ayu plugin package`.
// Prints p50/p95/p99 where it makes sense. Every number is specific to the
// machine it ran on; see docs/implementation-log.md for recorded runs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

Future<void> main(List<String> args) async {
  final packagePath = _option(args, '--package') ??
      p.join('..', '..', 'examples', 'example_plugin', 'build', 'ayu', 'example_plugin-1.0.0.ayu');
  final pluginCount = int.parse(_option(args, '--plugins') ?? '10');
  final package = File(packagePath);
  if (!package.existsSync()) {
    stderr.writeln('package not found: $packagePath (run `ayu plugin package` in examples/example_plugin first)');
    exitCode = 2;
    return;
  }

  final temp = await Directory.systemTemp.createTemp('ayu_bench_');
  final quiet = _QuietLogger();
  final host = PluginHost(
    rootDirectory: temp,
    profileId: 'AyuMC-1.8.9-release',
    logger: quiet,
  );
  await host.start();
  if (host.runtime == null) {
    stderr.writeln('dartaotruntime not found; cannot benchmark');
    exitCode = 2;
    return;
  }
  stdout.writeln('runtime: ${host.runtime}');
  stdout.writeln('host rss before: ${_mib(ProcessInfo.currentRss)} MiB');

  try {
    final variants = await _clonePackage(package, temp, pluginCount);

    // Cold start: install -> active, each a fresh process.
    final starts = <Duration>[];
    for (final variant in variants) {
      final watch = Stopwatch()..start();
      await host.install(variant.file);
      starts.add(watch.elapsed);
    }
    _report('cold install -> active (${variants.length} plugins, sequential)', starts);

    final workerRss = <int>[];
    for (final plugin in host.plugins) {
      final rss = await _rssOf(plugin.pid!);
      if (rss != null) workerRss.add(rss);
    }
    if (workerRss.isNotEmpty) {
      workerRss.sort();
      stdout.writeln('worker rss: median ${_mib(workerRss[workerRss.length ~/ 2])} MiB, '
          'max ${_mib(workerRss.last)} MiB, total ${_mib(workerRss.fold(0, (a, b) => a + b))} MiB');
    }
    stdout.writeln('host rss with ${variants.length} active plugins: ${_mib(ProcessInfo.currentRss)} MiB');

    // Command round trip against one plugin.
    final first = variants.first;
    final rtts = <Duration>[];
    for (var i = 0; i < 1000; i++) {
      final watch = Stopwatch()..start();
      await host.executeCommand(first.command('hello'), ['bench']);
      rtts.add(watch.elapsed);
    }
    _report('command round trip (1000 sequential)', rtts);

    // Event fan-out to every active plugin.
    host.contracts.registerProvider('bench_source', [
      EventContractSpec(id: 'player.join', version: Version(1, 0, 0), delivery: const DeliverySpec()),
    ]);
    const events = 20000;
    final fanout = Stopwatch()..start();
    var delivered = 0;
    for (var i = 0; i < events; i++) {
      delivered += host.dispatcher.publish('bench_source', PublishedEvent(contract: 'player.join', data: {'player': 'p$i'}));
    }
    fanout.stop();
    await host.executeCommand(first.command('stats'), []); // drains the channel
    final dropped = host.plugins.fold<int>(0, (sum, s) => sum + s.droppedEvents);
    final received = (await host.executeCommand(first.command('stats'), [])).message;
    stdout.writeln('event fan-out: $events events x ${variants.length} plugins enqueued in ${fanout.elapsedMilliseconds} ms '
        '(${(delivered / fanout.elapsedMilliseconds * 1000).round()} deliveries/s), dropped $dropped, first plugin reports "$received"');

    // Disable latency.
    final stops = <Duration>[];
    for (final variant in variants) {
      final watch = Stopwatch()..start();
      await host.disable(variant.id);
      stops.add(watch.elapsed);
    }
    _report('disable (graceful shutdown, ${variants.length} plugins)', stops);
    stdout.writeln('host rss after disable: ${_mib(ProcessInfo.currentRss)} MiB');
  } finally {
    await host.dispose();
    await temp.delete(recursive: true);
  }
}

final class _Variant {
  const _Variant(this.id, this.file, this.index);

  final String id;
  final File file;
  final int index;

  /// Commands are global, so each clone prefixes its own.
  String command(String name) => 'b${index}_$name';
}

/// Re-wraps the example plugin's artifact under distinct ids so several
/// instances can be active at once. Clones receive a config that makes the
/// example plugin register prefixed command names.
Future<List<_Variant>> _clonePackage(File source, Directory temp, int count) async {
  final opened = await AyuPackage.open(source);
  try {
    final target = RuntimeTarget.current();
    final artifact = opened.manifest.artifactFor(target);
    if (artifact == null) throw StateError('package has no artifact for $target');
    final bytes = await opened.readEntry(artifact.path);
    final variants = <_Variant>[];
    for (var i = 0; i < count; i++) {
      final id = 'bench_$i';
      final manifest = PluginManifest(
        id: id,
        name: 'Bench $i',
        version: Version(1, 0, 0),
        api: opened.manifest.api,
        artifacts: {target.id: artifact},
        capabilities: opened.manifest.capabilities,
        events: opened.manifest.events,
      );
      final file = File(p.join(temp.path, '$id.ayu'));
      await PackageWriter.write(output: file, manifest: manifest, entries: {
        artifact.path: bytes,
        'config/config.json': _utf8('{"greeting":"Hello","commandPrefix":"b${i}_"}'),
      });
      variants.add(_Variant(id, file, i));
    }
    return variants;
  } finally {
    await opened.close();
  }
}

void _report(String label, List<Duration> samples) {
  final sorted = samples.map((d) => d.inMicroseconds).toList()..sort();
  int pct(double q) => sorted[((sorted.length - 1) * q).round()];
  stdout.writeln('$label: p50 ${_ms(pct(0.5))} ms, p95 ${_ms(pct(0.95))} ms, p99 ${_ms(pct(0.99))} ms, max ${_ms(sorted.last)} ms');
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(2);
String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

Future<int?> _rssOf(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
    final line = result.stdout.toString().trim();
    final match = RegExp(r'"([\d,.\s]+) K"$').firstMatch(line);
    if (match == null) return null;
    return int.parse(match.group(1)!.replaceAll(RegExp(r'[^\d]'), '')) * 1024;
  }
  final status = File('/proc/$pid/status');
  if (!status.existsSync()) return null;
  final match = RegExp(r'VmRSS:\s+(\d+) kB').firstMatch(await status.readAsString());
  return match == null ? null : int.parse(match.group(1)!) * 1024;
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

final class _QuietLogger extends Logger {
  _QuietLogger() : super('bench');

  @override
  void info(String message) {}

  @override
  void warn(String message) {}
}
