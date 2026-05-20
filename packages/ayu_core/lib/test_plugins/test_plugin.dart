import 'package:ayu_plugin_api/ayu_plugin_api.dart';

class TestPlugin extends AyuPlugin {
  @override
  void onEnable() {
    logger.info('TestPlugin enabled!');
  }

  @override
  void onDisable() {
    logger.warn('TestPlugin disabled!');
  }
}
