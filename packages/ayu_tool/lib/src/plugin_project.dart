import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'tool_exception.dart';

/// A plugin source project: a Dart package plus an `ayu_plugin.yaml`.
final class PluginProject {
  PluginProject._({
    required this.root,
    required this.id,
    required this.name,
    required this.version,
    required this.api,
    required this.entry,
    required this.description,
    required this.authors,
    required this.homepage,
    required this.license,
    required this.capabilities,
    required this.dependencies,
    required this.assetDirectories,
    required this.configDirectory,
  });

  static const descriptorFileName = 'ayu_plugin.yaml';

  final Directory root;
  final String id;
  final String name;
  final Version version;
  final VersionConstraint api;

  /// Project-relative path of the Dart entry point.
  final String entry;
  final String? description;
  final List<String> authors;
  final String? homepage;
  final String? license;
  final Set<String> capabilities;
  final List<DependencySpec> dependencies;
  final List<String> assetDirectories;
  final String? configDirectory;

  File get entryFile => File(p.join(root.path, entry));
  Directory get buildDirectory => Directory(p.join(root.path, 'build', 'ayu'));

  static Future<PluginProject> load(Directory directory) async {
    final root = Directory(p.normalize(p.absolute(directory.path)));
    final descriptorFile = File(p.join(root.path, descriptorFileName));
    if (!await descriptorFile.exists()) {
      throw ToolException('no $descriptorFileName in ${root.path}');
    }
    final pubspecFile = File(p.join(root.path, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw ToolException('no pubspec.yaml in ${root.path}; a plugin project is a Dart package');
    }
    final YamlMap descriptor;
    final YamlMap pubspec;
    try {
      descriptor = _asMap(loadYaml(await descriptorFile.readAsString()), descriptorFileName);
      pubspec = _asMap(loadYaml(await pubspecFile.readAsString()), 'pubspec.yaml');
    } on YamlException catch (e) {
      throw ToolException('cannot parse project descriptor: ${e.message}');
    }

    final problems = <String>[];
    String? requireString(String key, {bool required = true}) {
      final value = descriptor[key];
      if (value == null) {
        if (required) problems.add('$key: is required');
        return null;
      }
      if (value is! String || value.isEmpty) {
        problems.add('$key: must be a non-empty string');
        return null;
      }
      return value;
    }

    final id = requireString('id');
    if (id != null && !PackageSpec.pluginIdPattern.hasMatch(id)) {
      problems.add('id: "$id" is invalid; ${PackageSpec.pluginIdRule}');
    }
    final name = requireString('name');
    final versionText = requireString('version', required: false) ?? pubspec['version']?.toString();
    Version? version;
    if (versionText == null) {
      problems.add('version: set it in $descriptorFileName or pubspec.yaml');
    } else {
      try {
        version = Version.parse(versionText);
      } on FormatException {
        problems.add('version: "$versionText" is not a semantic version');
      }
    }
    VersionConstraint? api;
    final apiText = requireString('api');
    if (apiText != null) {
      try {
        api = VersionConstraint.parse(apiText);
      } on FormatException {
        problems.add('api: "$apiText" is not a version constraint');
      }
    }
    final entry = requireString('entry', required: false) ?? 'bin/main.dart';
    if (!File(p.join(root.path, entry)).existsSync()) {
      problems.add('entry: $entry does not exist');
    }
    final authors = _stringList(descriptor['authors'], 'authors', problems);
    final capabilities = _stringList(descriptor['capabilities'], 'capabilities', problems).toSet();
    final dependencies = <DependencySpec>[];
    final rawDependencies = descriptor['dependencies'];
    if (rawDependencies is YamlList) {
      for (final item in rawDependencies) {
        if (item is YamlMap && item['id'] is String && item['version'] is String) {
          try {
            dependencies.add(DependencySpec(
              id: item['id'] as String,
              version: VersionConstraint.parse(item['version'] as String),
              optional: item['optional'] == true,
            ));
          } on FormatException {
            problems.add('dependencies: "${item['version']}" is not a version constraint');
          }
        } else {
          problems.add('dependencies: each entry needs string fields id and version');
        }
      }
    } else if (rawDependencies is YamlMap) {
      for (final entry in rawDependencies.entries) {
        try {
          dependencies.add(DependencySpec(id: '${entry.key}', version: VersionConstraint.parse('${entry.value}')));
        } on FormatException {
          problems.add('dependencies.${entry.key}: "${entry.value}" is not a version constraint');
        }
      }
    } else if (rawDependencies != null) {
      problems.add('dependencies: must be a list or a map');
    }
    final assets = _stringList(descriptor['assets'], 'assets', problems);
    for (final dir in assets) {
      if (!Directory(p.join(root.path, dir)).existsSync()) problems.add('assets: directory "$dir" does not exist');
    }
    final config = requireString('config', required: false);
    if (config != null && !Directory(p.join(root.path, config)).existsSync()) {
      problems.add('config: directory "$config" does not exist');
    }
    if (problems.isNotEmpty) {
      throw ToolException('invalid $descriptorFileName in ${root.path}', details: problems);
    }
    return PluginProject._(
      root: root,
      id: id!,
      name: name!,
      version: version!,
      api: api!,
      entry: entry,
      description: requireString('description', required: false),
      authors: authors,
      homepage: requireString('homepage', required: false),
      license: requireString('license', required: false),
      capabilities: capabilities,
      dependencies: dependencies,
      assetDirectories: assets,
      configDirectory: config,
    );
  }

  static YamlMap _asMap(Object? value, String what) {
    if (value is YamlMap) return value;
    throw ToolException('$what must be a YAML mapping');
  }

  static List<String> _stringList(Object? value, String key, List<String> problems) {
    if (value == null) return const [];
    if (value is YamlList && value.every((e) => e is String)) return value.cast<String>().toList();
    problems.add('$key: must be a list of strings');
    return const [];
  }
}
