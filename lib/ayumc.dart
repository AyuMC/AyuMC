import 'dart:io';
import 'package:ayu_core/ayu_core.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayumc/test_plugins/test_plugin.dart';
import 'package:ayu_core/plugins/plugin_discovery.dart';

void main() async {
  /// This is Create an instance of AyuServer
  ///
  /// AyuServer is the main class that manages the server lifecycle, plugins, commands, and events.
  ///
  /// [server.start()] method starts the server, enabling plugins and registering commands.
  /// [server.stop()] method stops the server, disabling plugins and performing cleanup.

  final server = AyuServer();

  /// This is Create a Logger instance for logging messages with a specific name.
  /// The Logger class provides methods for logging messages at different levels (info, warn, error).
  /// The logger will print messages to the console with timestamps and color coding based on the log level.
  /// In this case, the logger is named 'AyuMC', which will be included in all log messages for easy identification.
  /// Example usage:
  /// ```dart
  /// logger.info("This is an info message.");
  /// logger.warn("This is a warning message.");
  /// logger.error("This is an error message.");
  /// ```

  Logger logger = Logger('AyuMC');

  /// This is Registering a plugin with the server.
  /// The `register()` method is used to add a plugin to the server's plugin manager
  /// so that it can be enabled and used when the server starts. In this example, we are registering an instance of `TestPlugin`,
  ///  which is a simple plugin that logs messages when enabled and disabled.
  /// Example usage:
  /// ```dart
  /// server.plugins.register(MyCustomPlugin());
  /// ```

  server.plugins.register(TestPlugin());

  /// This is Discovering plugins in a specified directory.
  /// The `PluginDiscovery` class is responsible for scanning a directory for plugin manifests (e.g., `plugin.yaml` files) and loading the plugin information.
  /// The `discover()` method returns a list of `PluginManifest` objects, which contain metadata about each discovered plugin (such as name, version, and main entry point).
  /// In this example, we are looking for plugins in the `plugins` directory relative to the current working directory.
  /// Example usage:
  /// ```dart
  /// final discovery = PluginDiscovery(Directory('path/to/plugins'));
  /// final plugins = discovery.discover();
  /// for (final plugin in plugins) {
  ///   print('Discovered plugin: ${plugin.name} v${plugin.version} (main: ${plugin.main})');
  /// }

  final discovery = PluginDiscovery(Directory('plugins'));

  /// This is Logging discovered plugins.

  final plugins = discovery.discover();

  final resolver = PluginDependencyResolver();

  final result = resolver.resolve(plugins);

  if (!result.success) {
    print('Missing dependencies:');

    for (final error in result.missingDependencies) {
      print(error);
    }
  }

  /// This loop iterates through the list of discovered plugins and logs their name,
  ///  version, and main entry point using the logger instance. Each plugin's information is printed in a formatted string for easy readability.
  /// Example output:
  /// ```
  /// Discovered plugin: LeftManager v1.0.0 (main: left_manager)
  /// Discovered plugin: AuthPlugin v1.2.0 (main: auth_plugin)
  /// ```

  for (final plugin in plugins) {
    logger.info(
      'Discovered plugin: ${plugin.name} v${plugin.version} (main: ${plugin.main})',
    );
  }

  /// This is Starting the server and stopping it after a delay.
  /// The `start()` method initializes the server, enabling all registered plugins and making the server ready to handle commands and events.
  /// After starting the server, we wait for 3 seconds using `Future.delayed()`,
  /// and then call the `stop()` method to gracefully shut down the server, disabling all plugins and performing any necessary cleanup.

  await server.start();

  /// This is Waiting for 3 seconds before stopping the server.
  /// !TEST PURPOSE ONLY!

  await Future.delayed(Duration(seconds: 3));

  /// This is Stopping the server.
  /// The `stop()` method is called to gracefully shut down the server, which involves disabling all active plugins,
  ///  closing any open connections, and performing necessary cleanup tasks to ensure a clean shutdown process

  await server.stop();
}
