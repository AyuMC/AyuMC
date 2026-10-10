import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_store.dart';

/// Directory layout of a server installation. Every path the runtime touches
/// derives from here.
///
/// ```text
/// <root>/
/// ├── plugins/   regular plugin store (installed/, staging/, data/, state.json)
/// ├── events/    event pack store (same structure)
/// ├── config/    server.json (profile, network) and other host configuration
/// ├── logs/
/// └── cache/
/// ```
final class ServerLayout {
  ServerLayout(Directory root) : root = Directory(p.normalize(p.absolute(root.path)));

  final Directory root;

  PluginStoreLayout get plugins => PluginStoreLayout(Directory(p.join(root.path, 'plugins')));
  PluginStoreLayout get events => PluginStoreLayout(Directory(p.join(root.path, 'events')));
  Directory get config => Directory(p.join(root.path, 'config'));
  Directory get logs => Directory(p.join(root.path, 'logs'));
  Directory get cache => Directory(p.join(root.path, 'cache'));

  File get serverConfigFile => File(p.join(config.path, 'server.json'));

  Future<void> create() async {
    for (final dir in [root, config, logs, cache]) {
      await dir.create(recursive: true);
    }
  }
}
