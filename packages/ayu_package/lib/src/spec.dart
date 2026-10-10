/// Central description of the `.ayu` package layout. Nothing else in the
/// platform hard-codes these names.
abstract final class PackageSpec {
  static const fileExtension = '.ayu';

  /// Manifest format versions this implementation can read.
  static const supportedFormatVersions = <int>{1};
  static const currentFormatVersion = 1;

  static const manifestFileName = 'manifest.json';

  /// Directory holding the original sources (informational only).
  static const sourceDirectory = 'src';

  /// Directory holding per-target runtime artifacts: `bin/<target>/...`.
  static const artifactDirectory = 'bin';
  static const artifactFileName = 'plugin.aot';

  static const assetDirectory = 'assets';
  static const configDirectory = 'config';

  /// Default configuration file a package may ship under [configDirectory].
  static const defaultConfigFileName = 'config.json';

  static final RegExp pluginIdPattern = RegExp(r'^[a-z][a-z0-9_]{1,63}$');
  static const pluginIdRule =
      'plugin ids are 2-64 characters of lowercase letters, digits and underscores, starting with a letter';

  static final RegExp commandNamePattern = RegExp(r'^[a-z][a-z0-9_\-]{0,31}$');
  static final RegExp eventTypePattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

  static String artifactPath(String targetId) =>
      '$artifactDirectory/$targetId/$artifactFileName';
}

/// Hard limits applied while inspecting and extracting a package. All are
/// configurable by the host; the defaults are deliberately conservative.
final class PackageLimits {
  const PackageLimits({
    this.maxEntries = 10000,
    this.maxCompressedBytes = 128 << 20,
    this.maxUncompressedBytes = 256 << 20,
    this.maxEntryBytes = 128 << 20,
    this.maxManifestBytes = 256 << 10,
    this.maxEntryNameLength = 512,
    this.maxPathDepth = 32,
    this.maxCentralDirectoryBytes = 8 << 20,
    this.maxArtifacts = 16,
    this.maxDependencies = 64,
  });

  final int maxEntries;

  /// Size of the `.ayu` file itself.
  final int maxCompressedBytes;

  /// Sum of all declared uncompressed entry sizes.
  final int maxUncompressedBytes;
  final int maxEntryBytes;
  final int maxManifestBytes;
  final int maxEntryNameLength;
  final int maxPathDepth;
  final int maxCentralDirectoryBytes;
  final int maxArtifacts;
  final int maxDependencies;
}
