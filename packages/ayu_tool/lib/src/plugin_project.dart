import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:toml/toml.dart';
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
    this.packageType = PackageType.plugin,
    this.profiles = const [],
    this.provides = const [],
    this.events = const [],
  });

  static const descriptorFileName = 'ayu_plugin.yaml';
  static const tomlDescriptorFileName = 'ayu.package.toml';

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
  final PackageType packageType;
  final List<String> profiles;
  final List<EventContractSpec> provides;
  final List<ContractRequirement> events;

  File get entryFile => File(p.join(root.path, entry));
  Directory get buildDirectory => Directory(p.join(root.path, 'build', 'ayu'));

  static Future<PluginProject> load(Directory directory) async {
    final root = Directory(p.normalize(p.absolute(directory.path)));
    final tomlFile = File(p.join(root.path, tomlDescriptorFileName));
    final yamlFile = File(p.join(root.path, descriptorFileName));
    final pubspecFile = File(p.join(root.path, 'pubspec.yaml'));
    if (!await tomlFile.exists() && !await yamlFile.exists()) {
      throw ToolException('no $tomlDescriptorFileName or $descriptorFileName in ${root.path}');
    }
    if (!await pubspecFile.exists()) {
      throw ToolException('no pubspec.yaml in ${root.path}; a plugin project is a Dart package');
    }
    final String sourceName;
    final Map<String, Object?> descriptor;
    try {
      if (await tomlFile.exists()) {
        sourceName = tomlDescriptorFileName;
        descriptor = _plainMap(TomlDocument.parse(await tomlFile.readAsString()).toMap());
      } else if (await yamlFile.exists()) {
        sourceName = descriptorFileName;
        descriptor = _plainMap(_asMap(loadYaml(await yamlFile.readAsString()), descriptorFileName));
      } else {
        throw ToolException('no $tomlDescriptorFileName or $descriptorFileName in ${root.path}');
      }
    } on YamlException catch (e) {
      throw ToolException('cannot parse project descriptor: ${e.message}');
    } on ToolException {
      rethrow;
    } on Object catch (e) {
      throw ToolException('cannot parse project descriptor: $e');
    }
    final YamlMap pubspec;
    try {
      pubspec = _asMap(loadYaml(await pubspecFile.readAsString()), 'pubspec.yaml');
    } on YamlException catch (e) {
      throw ToolException('cannot parse pubspec.yaml: ${e.message}');
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
    if (rawDependencies is List) {
      for (final item in rawDependencies) {
        if (item is Map && item['id'] is String && item['version'] is String) {
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
    } else if (rawDependencies is Map) {
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
    final packageType = _packageType(descriptor['packageType'], problems);
    final profiles = _stringList(descriptor['profiles'], 'profiles', problems);
    final provides = _provides(descriptor['provides'], packageType, problems);
    final events = _events(descriptor['events'], packageType, problems);
    if (problems.isNotEmpty) {
      throw ToolException('invalid $sourceName in ${root.path}', details: problems);
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
      packageType: packageType,
      profiles: profiles,
      provides: provides,
      events: events,
    );
  }

  static PackageType _packageType(Object? value, List<String> problems) {
    if (value == null) return PackageType.plugin;
    final parsed = value is String ? PackageType.fromWire(value) : null;
    if (parsed == null) {
      problems.add('packageType: unknown "$value"');
      return PackageType.plugin;
    }
    return parsed;
  }

  static List<EventContractSpec> _provides(Object? value, PackageType type, List<String> problems) {
    if (value == null) return const [];
    if (type != PackageType.eventPack) {
      problems.add('provides: only an event pack may declare contracts');
      return const [];
    }
    if (value is! List) {
      problems.add('provides: must be a list');
      return const [];
    }
    final result = <EventContractSpec>[];
    for (final item in value) {
      if (item is! Map || item['id'] is! String || item['version'] is! String) {
        problems.add('provides: each contract needs string fields id and version');
        continue;
      }
      final sources = item['sources'];
      final schema = item['schema'];
      Version? version;
      try {
        version = Version.parse(item['version'] as String);
      } on FormatException {
        problems.add('provides.${item['id']}: version is not semantic');
      }
      final delivery = DeliverySpec.fromJson(item['delivery'], (message) => problems.add('provides.${item['id']}.delivery: $message'));
      if (version == null || delivery == null) continue;
      result.add(EventContractSpec(
        id: item['id'] as String,
        version: version,
        delivery: delivery,
        sources: sources is List ? sources.whereType<String>().toList() : const [],
        schema: schema is Map ? schema.map((key, value) => MapEntry('$key', '$value')) : const {},
        description: item['description'] is String ? item['description'] as String : null,
      ));
    }
    return result;
  }

  static List<ContractRequirement> _events(Object? value, PackageType type, List<String> problems) {
    if (value == null) return const [];
    if (type == PackageType.eventPack) {
      problems.add('events: an event pack provides contracts; it does not consume them');
      return const [];
    }
    if (value is! Map) {
      problems.add('events: must be a mapping with requires and/or optional');
      return const [];
    }
    final result = <ContractRequirement>[];
    for (final key in const ['requires', 'optional']) {
      final list = value[key];
      if (list == null) continue;
      if (list is! List) {
        problems.add('events.$key: must be a list');
        continue;
      }
      for (final item in list) {
        if (item is! Map || item['id'] is! String || item['version'] is! String) {
          problems.add('events.$key: each entry needs string fields id and version');
          continue;
        }
        try {
          result.add(ContractRequirement(
            id: item['id'] as String,
            version: VersionConstraint.parse(item['version'] as String),
            optional: key == 'optional',
          ));
        } on FormatException {
          problems.add('events.$key.${item['id']}: version is not a constraint');
        }
      }
    }
    return result;
  }

  static YamlMap _asMap(Object? value, String what) {
    if (value is YamlMap) return value;
    throw ToolException('$what must be a YAML mapping');
  }

  static List<String> _stringList(Object? value, String key, List<String> problems) {
    if (value == null) return const [];
    if (value is List && value.every((e) => e is String)) return value.cast<String>().toList();
    problems.add('$key: must be a list of strings');
    return const [];
  }

  static Map<String, Object?> _plainMap(Map<dynamic, dynamic> raw) => {
    for (final entry in raw.entries) '${entry.key}': _plain(entry.value),
  };

  static Object? _plain(Object? value) {
    if (value is Map) return _plainMap(value);
    if (value is List) return [for (final item in value) _plain(item)];
    return value;
  }
}
