// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'package:yaml/yaml.dart';

class PluginManifest {
  /// This is a class that represents the metadata of a plugin.
  /// It contains information such as the plugin's name, version, main entry point, author, description, website, and API version, as well as a list of dependencies.
  /// The [PluginManifest] class is used to store and manage the essential details of a plugin,
  /// which can be loaded from a YAML file (e.g., [plugin.yaml]) using the [PluginManifestLoader] class.

  final String name;
  final String version;
  final String main;
  final String author;
  final String description;
  final String website;
  final String apiVersion;
  final List<String> dependencies;

  /// This is a constructor for the [PluginManifest] class that initializes all the required fields.
  ///

  PluginManifest({
    required this.name,
    required this.version,
    required this.main,
    required this.author,
    required this.description,
    required this.website,
    required this.apiVersion,
    required this.dependencies,
  });

  /// This is an overridden `toString()` method that provides a string representation of the [PluginManifest] instance.
  /// The method returns a formatted string that includes all the properties of the plugin manifest,
  /// making it easier to read and debug when printing the manifest information to the console or logs.

  @override
  String toString() {
    return '''PluginManifest(
    name: $name,
     version: $version, 
     main: $main, 
     author: $author, 
     description: $description, 
     website: $website, 
     apiVersion: $apiVersion
     )''';
  }
}

/// This is a utility class that provides a static method to load a [PluginManifest] from a YAML file.
/// The [PluginManifestLoader] class reads the contents of a specified YAML file, parses it,
/// and constructs a [PluginManifest] object based on the data found in the file.
/// The `load()` method takes a [File] object as input, reads its contents as a string,
/// and uses the `loadYaml()` function from the `yaml` package to parse the YAML content into a Dart map.
/// It then extracts the relevant fields (such as name, version, main, author, description, website, apiVersion, and dependencies)
/// from the parsed YAML data and creates a new [PluginManifest] instance with that information.
/// The method also provides default values for optional fields (like author, description, website, apiVersion, and dependencies) if they are not specified in the YAML file.

class PluginManifestLoader {
  static PluginManifest load(File file) {
    final content = file.readAsStringSync();

    final yaml = loadYaml(content);

    return PluginManifest(
      name: yaml['name'],
      version: yaml['version'],
      main: yaml['main'],
      author: yaml['author'] ?? 'Unknown',
      description: yaml['description'] ?? 'No description',
      website: yaml['website'] ?? '',
      apiVersion: yaml['apiVersion'] ?? '1.0.0',
      dependencies:
          (yaml['dependencies'] as YamlList?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}
