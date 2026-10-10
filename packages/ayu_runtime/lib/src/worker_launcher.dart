import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;

import 'dart_runtime.dart';
import 'errors.dart';
import 'worker_process.dart';

/// Everything a launcher may use to build the worker command line.
final class PluginLaunchContext {
  const PluginLaunchContext({
    required this.manifest,
    required this.installDirectory,
    required this.dataDirectory,
    required this.artifact,
    required this.runtime,
  });

  final PluginManifest manifest;
  final Directory installDirectory;
  final Directory dataDirectory;
  final ArtifactSpec artifact;
  final DartAotRuntime runtime;

  File get artifactFile => File(p.joinAll([installDirectory.path, ...artifact.path.split('/')]));
}

/// Builds the process launch for a plugin. The production launcher runs the
/// packaged AOT snapshot under `dartaotruntime`; tests substitute their own.
abstract interface class WorkerLauncher {
  WorkerLaunchSpec launchSpec(PluginLaunchContext context);
}

final class AotWorkerLauncher implements WorkerLauncher {
  const AotWorkerLauncher();

  static const pluginIdVariable = 'AYUMC_PLUGIN_ID';

  @override
  WorkerLaunchSpec launchSpec(PluginLaunchContext context) {
    final artifact = context.artifactFile;
    if (!artifact.existsSync()) {
      throw PluginHostException(PluginHostErrorCode.startFailed,
          'artifact "${context.artifact.path}" is missing from ${context.installDirectory.path}');
    }
    return WorkerLaunchSpec(
      executable: context.runtime.executable,
      arguments: [artifact.path],
      workingDirectory: context.dataDirectory.path,
      environment: {pluginIdVariable: context.manifest.id},
    );
  }
}
