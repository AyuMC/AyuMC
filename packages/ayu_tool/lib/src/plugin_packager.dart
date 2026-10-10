import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;

import 'plugin_builder.dart';
import 'plugin_project.dart';
import 'tool_exception.dart';

/// Assembles a `.ayu` from a project and its built artifacts.
///
/// Layout: `manifest.json`, `bin/<target>/plugin.aot`, `src/**` (lib, bin,
/// pubspec and lock for dependency provenance), `assets/**`, `config/**`.
abstract final class PluginPackager {
  static const toolName = 'ayu';
  static const toolVersion = '0.1.0';

  static const _sourceFiles = ['pubspec.yaml', 'pubspec.lock', PluginProject.descriptorFileName, 'README.md', 'LICENSE'];
  static const _sourceDirectories = ['lib', 'bin'];

  static Future<File> package(
    PluginProject project,
    List<BuiltArtifact> artifacts, {
    File? output,
    PackageLimits limits = const PackageLimits(),
    DateTime? createdAt,
  }) async {
    if (artifacts.isEmpty) {
      throw const ToolException('at least one built artifact is required; run `ayu plugin build` first');
    }
    final entries = <String, Uint8List>{};
    final artifactSpecs = <String, ArtifactSpec>{};
    for (final built in artifacts) {
      final bytes = await built.file.readAsBytes();
      final spec = PackageWriter.describeArtifact(target: built.target, bytes: bytes, dartSdk: built.dartSdk);
      artifactSpecs[built.target.id] = spec;
      entries[spec.path] = bytes;
    }

    for (final name in _sourceFiles) {
      await _addFile(entries, project.root, name, '${PackageSpec.sourceDirectory}/$name', limits);
    }
    for (final dir in _sourceDirectories) {
      await _addTree(entries, project.root, dir, PackageSpec.sourceDirectory, limits, dartOnly: true);
    }
    for (final dir in project.assetDirectories) {
      await _addTree(entries, project.root, dir, PackageSpec.assetDirectory, limits, stripRoot: true);
    }
    if (project.configDirectory != null) {
      await _addTree(entries, project.root, project.configDirectory!, PackageSpec.configDirectory, limits, stripRoot: true);
    }

    final manifest = PluginManifest(
      id: project.id,
      name: project.name,
      version: project.version,
      api: project.api,
      description: project.description,
      authors: project.authors,
      homepage: project.homepage,
      license: project.license,
      entryPoint: '${PackageSpec.sourceDirectory}/${p.url.joinAll(p.split(project.entry))}',
      artifacts: artifactSpecs,
      dependencies: project.dependencies,
      capabilities: project.capabilities,
      packageType: project.packageType,
      profiles: project.profiles,
      provides: project.provides,
      events: project.events,
      build: BuildInfo(
        tool: toolName,
        toolVersion: toolVersion,
        dartSdk: artifacts.first.dartSdk.toString(),
        createdAt: createdAt ?? DateTime.now().toUtc(),
      ),
    );

    final file = output ??
        File(p.join(project.buildDirectory.path, '${project.id}-${project.version}${PackageSpec.fileExtension}'));
    await PackageWriter.write(output: file, manifest: manifest, entries: entries, limits: limits);
    return file;
  }

  static Future<void> _addFile(
      Map<String, Uint8List> entries, Directory root, String relative, String archivePath, PackageLimits limits) async {
    final file = File(p.join(root.path, relative));
    if (!await file.exists()) return;
    _checkPath(archivePath, limits);
    entries[archivePath] = await file.readAsBytes();
  }

  static Future<void> _addTree(
    Map<String, Uint8List> entries,
    Directory root,
    String relativeDir,
    String archiveRoot,
    PackageLimits limits, {
    bool dartOnly = false,
    bool stripRoot = false,
  }) async {
    final dir = Directory(p.join(root.path, relativeDir));
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (dartOnly && !entity.path.endsWith('.dart')) continue;
      final relativeToRoot = p.relative(entity.path, from: stripRoot ? dir.path : root.path);
      final archivePath = p.url.joinAll([archiveRoot, ...p.split(relativeToRoot)]);
      _checkPath(archivePath, limits);
      if (entries.containsKey(archivePath)) {
        throw ToolException('"$archivePath" would be added twice; check overlapping asset directories');
      }
      entries[archivePath] = await entity.readAsBytes();
    }
  }

  static void _checkPath(String archivePath, PackageLimits limits) {
    final reason = PluginManifest.describeUnsafeArchivePath(archivePath, limits);
    if (reason != null) throw ToolException('cannot package "$archivePath": $reason');
  }
}
