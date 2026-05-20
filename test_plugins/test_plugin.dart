import 'package:ayu_plugin_api/ayu_plugin_api.dart';

class TestPlugin extends AyuPlugin {
  @override
  void onEnable() {
    logger.info("Hello from TestPlugin!");
  }

  @override
  void onDisable() {
    logger.warn("Goodbye from TestPlugin!");
  }
}
