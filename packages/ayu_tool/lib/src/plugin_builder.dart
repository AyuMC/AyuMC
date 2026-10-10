import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'dart_sdk.dart';
import 'plugin_project.dart';
import 'tool_exception.dart';

/// A compiled runtime artifact for one target.
final class BuiltArtifact {
  const BuiltArtifact({required this.target, required this.file, required this.dartSdk});

  final RuntimeTarget target;
  final File file;
  final Version dartSdk;
}

/// Compiles a plugin entry point to AOT snapshots with `dart compile
/// aot-snapshot`. Cross-compilation follows the SDK's own support matrix:
/// any 64-bit host can target Linux; other OS targets must be built on
/// that OS.
final class PluginBuilder {
  const PluginBuilder({required this.sdk, this.compileTimeout = const Duration(minutes: 10)});

  final DartSdk sdk;
  final Duration compileTimeout;

  Future<BuiltArtifact> build(PluginProject project, RuntimeTarget target, {Directory? outputDirectory}) async {
    final out = Directory(p.join((outputDirectory ?? project.buildDirectory).path, target.id));
    await out.create(recursive: true);
    final artifact = File(p.join(out.path, PackageSpec.artifactFileName));
    final args = <String>['compile', 'aot-snapshot', project.entryFile.path, '-o', artifact.path];
    if (target != sdk.target) {
      if (target.os != TargetOs.linux) {
        throw ToolException(
            'cannot build ${target.id} on ${sdk.target.id}: the Dart SDK only cross-compiles to Linux; build on a ${target.os.name} machine');
      }
      args.addAll(['--target-os=${target.os.name}', '--target-arch=${target.arch.name}']);
    }
    stderr.writeln('compiling ${project.id} for ${target.id} with Dart ${sdk.version}');
    final process = await Process.start(sdk.dartExecutable, args, workingDirectory: project.root.path, runInShell: false);
    final output = StringBuffer();
    final drain = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(output.write),
    ]);
    final int code;
    try {
      code = await process.exitCode.timeout(compileTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw ToolException('dart compile did not finish within ${compileTimeout.inMinutes} minutes');
    }
    await drain;
    if (code != 0 || !await artifact.exists()) {
      throw ToolException('dart compile aot-snapshot failed for ${target.id} (exit code $code)',
          details: output.toString().trim().split('\n'));
    }
    return BuiltArtifact(target: target, file: artifact, dartSdk: sdk.version);
  }
}
