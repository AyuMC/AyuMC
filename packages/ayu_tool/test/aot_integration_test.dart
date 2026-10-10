@Tags(['aot'])
library;

import 'dart:async';
import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:ayu_tool/ayu_tool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Phase B proof: the example plugin is compiled with `dart compile
/// aot-snapshot`, packaged into a real `.ayu`, installed into a running
/// host and executed by `dartaotruntime` in its own process.
void main() {
  late Directory temp;
  late DartSdk sdk;
  late DartAotRuntime runtime;
  late File packageFile;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('ayu_aot_test_');
    sdk = await DartSdk.locate();
    runtime = await const DartRuntimeLocator().locate(
      explicitPath: p.join(
        p.dirname(sdk.dartExecutable),
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    );
    final project = await PluginProject.load(
      Directory(p.join('..', '..', 'examples', 'example_plugin')),
    );
    final built = await PluginBuilder(sdk: sdk).build(
      project,
      sdk.target,
      outputDirectory: Directory(p.join(temp.path, 'build')),
    );
    packageFile = await PluginPackager.package(project, [
      built,
    ], output: File(p.join(temp.path, 'example_plugin.ayu')));
  });

  tearDownAll(() => temp.delete(recursive: true));

  test(
    'the packaged archive is well-formed and carries the artifact for this machine',
    () async {
      final package = await AyuPackage.open(packageFile);
      try {
        await package.verifyArtifacts();
        expect(package.manifest.id, 'example_plugin');
        expect(package.manifest.artifactFor(sdk.target)?.dartSdk, sdk.version);
        expect(
          package.entries.map((e) => e.name),
          containsAll([
            'manifest.json',
            'bin/${sdk.target.id}/plugin.aot',
            'src/lib/example_plugin.dart',
            'src/bin/main.dart',
            'src/pubspec.yaml',
            'config/config.json',
            'assets/messages.json',
          ]),
        );
      } finally {
        await package.close();
      }
    },
  );

  test('packaging is reproducible for identical inputs', () async {
    final project = await PluginProject.load(
      Directory(p.join('..', '..', 'examples', 'example_plugin')),
    );
    final artifact = BuiltArtifact(
      target: sdk.target,
      file: File(
        p.join(temp.path, 'build', sdk.target.id, PackageSpec.artifactFileName),
      ),
      dartSdk: sdk.version,
    );
    final stamp = DateTime.utc(2026, 1, 1);
    final a = await PluginPackager.package(
      project,
      [artifact],
      output: File(p.join(temp.path, 'a.ayu')),
      createdAt: stamp,
    );
    final b = await PluginPackager.package(
      project,
      [artifact],
      output: File(p.join(temp.path, 'b.ayu')),
      createdAt: stamp,
    );
    expect(await a.readAsBytes(), await b.readAsBytes());
  });

  test(
    'install, command, event, disable, enable and uninstall under dartaotruntime',
    () async {
      final host = PluginHost(
        rootDirectory: Directory(p.join(temp.path, 'plugins')),
        runtime: runtime,
        options: const PluginRuntimeOptions(
          helloTimeout: Duration(seconds: 20),
          initTimeout: Duration(seconds: 20),
        ),
      );
      await host.start();
      try {
        var ticks = 0;
        final ticker = Stopwatch()..start();
        final timer = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => ticks++,
        );

        final watch = Stopwatch()..start();
        final installed = await host.install(packageFile);
        final installLatency = watch.elapsed;
        timer.cancel();
        expect(installed.state, PluginState.active);
        expect(installed.pid, isNotNull);
        expect(
          ticks,
          greaterThan(ticker.elapsedMilliseconds ~/ 20 ~/ 4),
          reason: 'host loop stayed responsive',
        );

        final hello = await host.executeCommand('hello', ['Ayu']);
        expect(hello.success, isTrue);
        expect(hello.message, 'Hello, Ayu!');
        expect(
          (await host.executeCommand('hi', [])).message,
          'Hello, console!',
        );

        expect(host.emitEvent('player.join', {'player': 'steve'}), 1);
        expect(
          (await host.executeCommand('stats', [])).message,
          startsWith('joins=1'),
        );

        final pid = installed.pid!;
        final disabled = await host.disable('example_plugin');
        expect(disabled.state, PluginState.disabled);
        expect(disabled.lastExitCode, 0);
        expect(await _processGone(pid), isTrue);

        final enabled = await host.enable('example_plugin');
        expect(enabled.state, PluginState.active);
        expect(enabled.pid, isNot(pid));
        expect(
          (await host.executeCommand('stats', [])).message,
          startsWith('joins=0'),
          reason: 'fresh process, fresh state',
        );

        await host.uninstall('example_plugin');
        expect(host.plugins, isEmpty);
        expect(host.layout.installed.listSync(), isEmpty);

        stdout.writeln(
          'measured: hot install to active (AOT, this machine) = ${installLatency.inMilliseconds} ms',
        );
      } finally {
        await host.dispose();
      }
    },
  );
}

Future<bool> _processGone(int pid) async {
  for (var i = 0; i < 50; i++) {
    final exists = Platform.isWindows
        ? (await Process.run('tasklist', [
            '/FI',
            'PID eq $pid',
            '/NH',
            '/FO',
            'CSV',
          ])).stdout.toString().contains('"$pid"')
        : (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
    if (!exists) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}
