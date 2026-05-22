import 'dart:io';
import 'package:ayu_core/ayu_core.dart';
import 'package:ayumc/test_plugins/test_plugin.dart';
import 'package:ayu_core/plugins/plugin_manifest.dart';

void main() async {
  final server = AyuServer();
  server.plugins.register(TestPlugin());
  final manifest = PluginManifestLoader.load(
    File('plugins/join_manager/plugin.yaml'),
  );
  print(manifest);
  await server.start();

  await Future.delayed(Duration(seconds: 3));

  await server.stop();
}
