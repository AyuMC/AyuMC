import 'plugin_manifest.dart';

/// This is a class that represents the result of resolving plugin dependencies.
/// It contains a boolean `success` that indicates whether all dependencies were successfully resolved,
/// and a list of strings `missingDependencies` that contains the names of any dependencies that were not found among the provided plugins.
/// The `DependencyResult` class is used to encapsulate the outcome of the dependency resolution process performed by the `PluginDependencyResolver` class.
/// When the `resolve()` method of the `PluginDependencyResolver` is called with a list of `PluginManifest` objects,
/// it checks each plugin's declared dependencies against the names of the available plugins.
/// If any dependencies are missing, they are added to the `missingDependencies` list, and the `success` flag is set to `false`.
/// If all dependencies are resolved successfully, `success` is `true` and `missingDependencies` will be empty.

class DependencyResult {
  /// This is a constructor for the [DependencyResult] class that initializes the [success] and [missingDependencies] fields.
  /// The [success] parameter indicates whether the dependency resolution was successful (i.e., all dependencies were found),
  /// and the [missingDependencies] parameter is a list of strings that contains the names of any dependencies that were not resolved.
  /// The [DependencyResult] class is used to encapsulate the outcome of the dependency resolution process performed by the [PluginDependencyResolver] class.
  /// When the [resolve()] method of the [PluginDependencyResolver] is called with a list of [PluginManifest] objects, it checks each plugin's declared dependencies against the names of the available plugins.
  /// If any dependencies are missing, they are added to the [missingDependencies] list, and the [success] flag is set to [false].
  /// If all dependencies are resolved successfully, [success] is true and [missingDependencies] will be empty.
  final bool success;

  /// This is a list of strings that contains the names of any dependencies that were not resolved during the dependency resolution process.
  /// If the [success] flag is `false`, this list will contain the names of the missing dependencies that were not found among the provided plugins.
  /// If the [success] flag is `true`, this list will be empty, indicating that all dependencies were successfully resolved.

  final List<String> missingDependencies;

  /// This is a constructor for the [DependencyResult] class that initializes the [success] and [missingDependencies] fields.
  /// The [success] parameter indicates whether the dependency resolution was successful (i.e., all dependencies were found),
  /// and the [missingDependencies] parameter is a list of strings that contains the names of any dependencies that were not resolved.
  /// The [DependencyResult] class is used to encapsulate the outcome of the dependency resolution process performed by the [PluginDependencyResolver] class.
  /// When the [resolve()] method of the [PluginDependencyResolver] is called with a list of [PluginManifest] objects,
  /// it checks each plugin's declared dependencies against the names of the available plugins.
  /// If any dependencies are missing, they are added to the [missingDependencies] list, and the [success] flag is set to false.
  /// If all dependencies are resolved successfully, [success] is true and [missingDependencies] will be empty.

  DependencyResult({required this.success, required this.missingDependencies});
}

/// This is a class that resolves plugin dependencies based on their manifests.
/// The [PluginDependencyResolver] class provides a method `resolve()` that takes a list of [PluginManifest] objects and checks
/// If all declared dependencies for each plugin are present in the list of available plugins.
/// The `resolve()` method returns a [DependencyResult] object that indicates whether the dependency resolution was successful and
/// lists any missing dependencies that were not found among the provided plugins.
/// The `resolve()` method works by first creating a set of plugin names from the provided list of [PluginManifest] objects.
/// It then iterates through each plugin and its declared dependencies, checking if each dependency is present in the set of plugin names.
/// If a dependency is missing, it is added to the list of missing dependencies. Finally, the method
/// returns a [DependencyResult] indicating the success of the resolution and any missing dependencies.

class PluginDependencyResolver {
  /// This is a method that resolves plugin dependencies based on their manifests.
  /// The `resolve()` method takes a list of [PluginManifest] objects as input and checks
  /// If all declared dependencies for each plugin are present in the list of available plugins.
  /// The method returns a [DependencyResult] object that indicates whether the dependency resolution was successful and
  /// Lists any missing dependencies that were not found among the provided plugins.
  /// The `resolve()` method works by first creating a set of plugin names from the provided list of [PluginManifest] objects.
  /// It then iterates through each plugin and its declared dependencies, checking if each dependency is present in the set of plugin names.
  /// If a dependency is missing, it is added to the list of missing dependencies. Finally, the method returns a [DependencyResult]
  /// Indicating the success of the resolution and any missing dependencies.

  DependencyResult resolve(List<PluginManifest> plugins) {
    /// This line creates a set of plugin names from the provided list of [PluginManifest] objects.
    /// It uses the `map()` method to extract the `name` property from each plugin manifest and then converts the resulting iterable into a set using `toSet()`.
    final pluginNames = plugins.map((e) => e.name).toSet();

    /// This line initializes an empty list of strings called `missing`, which will be used to store the names of any dependencies that are not found among the provided plugins.

    final missing = <String>[];

    /// This loop iterates through each plugin in the list of [PluginManifest] objects and checks its declared dependencies against the set of available plugin names.
    /// For each plugin, it iterates through its `dependencies` list and checks if each dependency is present in the `pluginNames` set.
    /// If a dependency is not found in the set of plugin names, it means that the dependency is missing, and a string indicating the missing
    /// Dependency (in the format "pluginName -> missing dependency: dependencyName") is added to the `missing` list.
    /// After checking all plugins and their dependencies, the method returns a [DependencyResult] object where
    /// `success` is `true` if no dependencies are missing (i.e., `missing` list is empty), and `false` otherwise.
    /// The `missingDependencies` field of the [DependencyResult] contains the list of any missing dependencies that were identified during the resolution process.

    for (final plugin in plugins) {
      for (final dependency in plugin.dependencies) {
        if (!pluginNames.contains(dependency)) {
          missing.add('${plugin.name} -> missing dependency: $dependency');
        }
      }
    }

    /// This line returns a [DependencyResult] object that indicates whether the dependency resolution was successful and lists any missing dependencies.
    /// The `success` parameter is set to `true` if the `missing` list is empty (indicating that all dependencies were resolved successfully),
    /// And `false` if there are any missing dependencies.
    /// The `missingDependencies` parameter is set to the list of missing dependencies that were identified during the resolution process.

    return DependencyResult(
      success: missing.isEmpty,
      missingDependencies: missing,
    );
  }
}
