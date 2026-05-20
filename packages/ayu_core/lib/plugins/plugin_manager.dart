import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

class PluginManager {
  final Logger logger = Logger('Plugins');

  final List<AyuPlugin> _plugins = [];

  void register(AyuPlugin plugin) {
    plugin.logger = PluginLogger(plugin.runtimeType.toString());

    _plugins.add(plugin);

    logger.info('Registered plugin: ${plugin.runtimeType}');

    plugin.onLoad();
  }

  void enableAll() {
    for (final plugin in _plugins) {
      plugin.onEnable();
      logger.info('Enabled plugin: ${plugin.runtimeType}');
    }
  }

  void disableAll() {
    for (final plugin in _plugins) {
      plugin.onDisable();
      logger.warn('Disabled plugin: ${plugin.runtimeType}');
    }
  }

  List<AyuPlugin> get plugins => _plugins;
}
