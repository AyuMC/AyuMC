import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Absolute path of a JIT fixture script under `test/fixtures`.
String fixture(String name) => p.normalize(p.absolute(p.join('test', 'fixtures', '$name.dart')));

/// The Dart VM used to execute JIT fixtures as workers.
///
/// `dart test` runs under the `dart` CLI, which spawns a separate `dartvm`
/// child for scripts; launching `dartvm` directly keeps each fixture a
/// single process so pids, kills and exit codes refer to the real worker.
final String dartExecutable = () {
  final bin = File(Platform.resolvedExecutable).parent.path;
  final vm = File(p.join(bin, Platform.isWindows ? 'dartvm.exe' : 'dartvm'));
  return vm.existsSync() ? vm.path : Platform.resolvedExecutable;
}();

/// `dartaotruntime` next to the Dart VM, or `null` when absent.
String? get siblingAotRuntime {
  final bin = File(Platform.resolvedExecutable).parent.path;
  final file = File(p.join(bin, Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'));
  return file.existsSync() ? file.path : null;
}

/// Fake runtime descriptor pointing at the JIT VM. Tests that need the real
/// `dartaotruntime` locate it explicitly.
final DartAotRuntime jitRuntime = DartAotRuntime(
  executable: dartExecutable,
  version: Version.parse(RegExp(r'^(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)').firstMatch(Platform.version)!.group(1)!),
  target: RuntimeTarget.current(),
);

final Logger testLogger = Logger('test');

/// Profile used by host tests. Packages with an empty profile list accept it.
const testProfileId = 'AyuMC-1.8.9-release';

/// Runs the fixture named in the manifest description (`fixture:<name>`)
/// instead of the packaged artifact, so host-level tests exercise the full
/// lifecycle without an AOT compile per test run.
final class JitFixtureLauncher implements WorkerLauncher {
  const JitFixtureLauncher();

  @override
  WorkerLaunchSpec launchSpec(PluginLaunchContext context) {
    final description = context.manifest.description ?? '';
    if (description.startsWith('source:')) {
      return WorkerLaunchSpec(
        executable: dartExecutable,
        arguments: [description.substring('source:'.length)],
        workingDirectory: context.dataDirectory.path,
      );
    }
    final name = description.startsWith('fixture:') ? description.substring('fixture:'.length) : 'worker_ok';
    return WorkerLaunchSpec(
      executable: dartExecutable,
      arguments: [fixture(name)],
      workingDirectory: context.dataDirectory.path,
    );
  }
}

/// Writes a syntactically valid `.ayu` whose artifact is a placeholder (the
/// JIT launcher never executes it).
Future<File> writeFixturePackage(
  Directory dir, {
  required String id,
  String version = '1.0.0',
  String fixtureName = 'worker_ok',
  Set<String> capabilities = const {'commands', 'events', 'config'},
  List<DependencySpec> dependencies = const [],
  RuntimeTarget? target,
  Version? dartSdk,
  String api = '^1.0.0',
  String? description,
  PackageType packageType = PackageType.plugin,
  List<String> profiles = const [],
  List<EventContractSpec> provides = const [],
  List<ContractRequirement>? events,
  Map<String, Uint8List> extraEntries = const {},
}) async {
  final bytes = Uint8List.fromList('placeholder artifact for $id $version'.codeUnits);
  final artifact = PackageWriter.describeArtifact(
    target: target ?? RuntimeTarget.current(),
    bytes: bytes,
    dartSdk: dartSdk ?? jitRuntime.version,
  );
  final manifest = PluginManifest(
    id: id,
    name: 'Fixture $id',
    version: Version.parse(version),
    api: VersionConstraint.parse(api),
    description: description ?? 'fixture:$fixtureName',
    entryPoint: 'src/main.dart',
    artifacts: {artifact.target.id: artifact},
    dependencies: dependencies,
    capabilities: capabilities,
    packageType: packageType,
    profiles: profiles,
    provides: provides,
    events: events ??
        (packageType == PackageType.plugin && capabilities.contains('events')
            ? [ContractRequirement(id: 'test.event', version: VersionConstraint.parse('^1.0.0'), optional: true)]
            : const []),
  );
  final file = File(p.join(dir.path, '$id-$version.ayu'));
  await PackageWriter.write(
    output: file,
    manifest: manifest,
    entries: {
      artifact.path: bytes,
      'src/main.dart': Uint8List.fromList('// fixture'.codeUnits),
      ...extraEntries,
    },
  );
  return file;
}

/// Fast deadlines so failure paths finish in seconds.
const fastOptions = PluginRuntimeOptions(
  helloTimeout: Duration(seconds: 8),
  initTimeout: Duration(seconds: 8),
  requestTimeout: Duration(seconds: 3),
  commandTimeout: Duration(seconds: 3),
  shutdownGracePeriod: Duration(seconds: 2),
  killTimeout: Duration(seconds: 5),
  restartWindow: Duration(seconds: 30),
);

/// True once the OS no longer lists [pid]. Polls briefly because exit code
/// delivery and process-table removal are not atomic.
Future<bool> processGone(int pid, {Duration within = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (!await _processExists(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return !await _processExists(pid);
}

Future<bool> _processExists(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
    return result.stdout.toString().contains('"$pid"');
  }
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}
