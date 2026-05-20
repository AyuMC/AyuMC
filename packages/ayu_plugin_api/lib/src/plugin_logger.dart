class PluginLogger {
  final String pluginName;

  PluginLogger(this.pluginName);

  void info(String message) {
    print('[$pluginName] [INFO]: $message');
  }

  void warn(String message) {
    print('[$pluginName] [WARN]: $message');
  }

  void error(String message) {
    print('[$pluginName] [ERROR]: $message');
  }
}
