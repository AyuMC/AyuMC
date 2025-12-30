/// Represents a world dimension (overworld, nether, end).
///
/// Uses the naming convention 'map' instead of 'world' as per project specs.
enum MapDimension {
  /// The main overworld dimension.
  overworld('minecraft:overworld', 'map'),

  /// The nether dimension.
  nether('minecraft:the_nether', 'map_nether'),

  /// The end dimension.
  end('minecraft:the_end', 'map_end');

  /// The Minecraft namespace identifier.
  final String namespaceId;

  /// The folder name for this dimension.
  final String folderName;

  const MapDimension(this.namespaceId, this.folderName);
}
