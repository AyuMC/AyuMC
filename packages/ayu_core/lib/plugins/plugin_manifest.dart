// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'package:yaml/yaml.dart';

class PluginManifest {
  final String name;
  final String version;
  final String main;

  PluginManifest({
    required this.name,
    required this.version,
    required this.main,
  });

  @override
  String toString() {
    return 'PluginManifest(name: $name, version: $version, main: $main)';
  }
}

class PluginManifestLoader {
  static PluginManifest load(File file) {
    final content = file.readAsStringSync();

    final yaml = loadYaml(content);

    return PluginManifest(
      name: yaml['name'],
      version: yaml['version'],
      main: yaml['main'],
    );
  }
}
