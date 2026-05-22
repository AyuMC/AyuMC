import 'dart:io';
import 'plugin_manifest.dart';


class PluginDiscovery {
  final Directory pluginsDirectory;

  PluginDiscovery(this.pluginsDirectory);

  List<PluginManifest> discover() {
    final manifests = <PluginManifest>[];

    if (!pluginsDirectory.existsSync()) {
      return manifests;
    }

    final pluginFolders = pluginsDirectory.listSync();

    for (final entity in pluginFolders) {
      if (entity is! Directory) continue;

      final manifestFile = File('${entity.path}/plugin.yaml');

      if (!manifestFile.existsSync()) {
        continue;
      }

      final manifest = PluginManifestLoader.load(manifestFile);

      manifests.add(manifest);
    }

    return manifests;
  }
}
