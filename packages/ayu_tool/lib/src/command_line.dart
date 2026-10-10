import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ayu_package/ayu_package.dart';

import 'dart_sdk.dart';
import 'plugin_builder.dart';
import 'plugin_packager.dart';
import 'plugin_project.dart';
import 'tool_exception.dart';

/// `ayu plugin build|package|inspect`.
final class AyuCommandLine {
  AyuCommandLine() {
    _runner = CommandRunner<int>('ayu', 'AyuMC developer tools')..addCommand(_PluginCommand());
  }

  late final CommandRunner<int> _runner;

  Future<int> run(List<String> args) async {
    try {
      return await _runner.run(args) ?? 0;
    } on UsageException catch (e) {
      stderr.writeln(e);
      return 64;
    } on ToolException catch (e) {
      stderr.writeln('error: $e');
      return 1;
    } on PackageException catch (e) {
      stderr.writeln('error: $e');
      return 1;
    }
  }
}

final class _PluginCommand extends Command<int> {
  _PluginCommand() {
    addSubcommand(_BuildCommand());
    addSubcommand(_PackageCommand());
    addSubcommand(_InspectCommand());
  }

  @override
  String get name => 'plugin';

  @override
  String get description => 'Build, package and inspect AyuMC plugins.';
}

mixin _ProjectOptions on Command<int> {
  void addProjectOptions() {
    argParser
      ..addOption('project', abbr: 'p', help: 'Plugin project directory.', defaultsTo: '.')
      ..addMultiOption('target', abbr: 't',
          help: 'Runtime target(s) to build, e.g. windows-x64 or linux-x64. Defaults to this machine.',
          allowed: [for (final t in RuntimeTarget.supported) t.id]);
  }

  Future<PluginProject> loadProject() => PluginProject.load(Directory(argResults!['project'] as String));

  List<RuntimeTarget> targets(DartSdk sdk) {
    final requested = argResults!['target'] as List<String>;
    if (requested.isEmpty) return [sdk.target];
    return [for (final id in requested) RuntimeTarget.tryParse(id)!];
  }
}

final class _BuildCommand extends Command<int> with _ProjectOptions {
  _BuildCommand() {
    addProjectOptions();
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Compile the plugin to AOT snapshot(s) under build/ayu/<target>/.';

  @override
  Future<int> run() async {
    final project = await loadProject();
    final sdk = await DartSdk.locate();
    final builder = PluginBuilder(sdk: sdk);
    for (final target in targets(sdk)) {
      final built = await builder.build(project, target);
      stdout.writeln('built ${built.file.path} (${await built.file.length()} bytes, Dart ${built.dartSdk})');
    }
    return 0;
  }
}

final class _PackageCommand extends Command<int> with _ProjectOptions {
  _PackageCommand() {
    addProjectOptions();
    argParser.addOption('out', abbr: 'o', help: 'Output .ayu path. Defaults to build/ayu/<id>-<version>.ayu');
  }

  @override
  String get name => 'package';

  @override
  String get description => 'Build (if needed) and assemble the .ayu archive.';

  @override
  Future<int> run() async {
    final project = await loadProject();
    final sdk = await DartSdk.locate();
    final builder = PluginBuilder(sdk: sdk);
    final artifacts = [for (final target in targets(sdk)) await builder.build(project, target)];
    final out = argResults!['out'] as String?;
    final file = await PluginPackager.package(project, artifacts, output: out == null ? null : File(out));
    final package = await AyuPackage.open(file);
    try {
      await package.verifyArtifacts();
      stdout.writeln('packaged ${file.path} (${await file.length()} bytes, ${package.entries.length} entries)');
      for (final artifact in package.manifest.artifacts.values) {
        stdout.writeln('  ${artifact.target.id}: ${artifact.path} sha256 ${artifact.sha256.substring(0, 16)}… (Dart ${artifact.dartSdk})');
      }
    } finally {
      await package.close();
    }
    return 0;
  }
}

final class _InspectCommand extends Command<int> {
  @override
  String get name => 'inspect';

  @override
  String get description => 'Validate a .ayu file and print its manifest and contents.';

  @override
  String get invocation => 'ayu plugin inspect <file.ayu>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) throw UsageException('expected exactly one .ayu file', invocation);
    final package = await AyuPackage.open(File(rest.single));
    try {
      await package.verifyArtifacts();
      stdout.writeln(package.manifest.toJsonString());
      stdout.writeln();
      for (final entry in package.entries) {
        if (!entry.isDirectory) stdout.writeln('${entry.uncompressedSize.toString().padLeft(10)}  ${entry.name}');
      }
      stdout.writeln('\nartifacts verified; package is well-formed for targets: ${package.manifest.artifacts.keys.join(', ')}');
    } finally {
      await package.close();
    }
    return 0;
  }
}
