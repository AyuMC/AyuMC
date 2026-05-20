import 'package:ayu_plugin_api/src/plugin_logger.dart';

abstract class AyuPlugin {
  late PluginLogger logger;

  void onLoad() {}
  void onUnload() {}
  void onEnable() {}
  void onDisable() {}
}
