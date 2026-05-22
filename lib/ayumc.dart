import 'dart:io';
import 'package:ayu_core/ayu_core.dart';
import 'package:ayumc/test_plugins/test_plugin.dart';
import 'package:ayu_core/plugins/plugin_discovery.dart';

void main() async {
  final server = AyuServer();

  server.plugins.register(TestPlugin());

  final discovery = PluginDiscovery(Directory('plugins'));

  final plugins = discovery.discover();

  for (final plugin in plugins) {
    print(plugin);
  }

  await server.start();

  await Future.delayed(Duration(seconds: 3));

  await server.stop();
}
