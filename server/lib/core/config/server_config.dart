/// Server runtime configuration.
///
/// NOTE: Some features (Chunk Streaming) depend on exact protocol packet IDs.
/// Until the target Minecraft client version is pinned, those features stay
/// disabled by default to avoid disconnects.
class ServerConfig {
  ServerConfig._();

  /// When true, the server will send initial chunks on join.
  ///
  /// Temporarily disabled to debug connection issues.
  /// Will be re-enabled after fixing chunk packet encoding.
  static const bool kEnableChunkStreaming = false;

  /// Default view distance (in chunks) for initial chunk stream.
  static const int kInitialChunkViewDistance = 4;

  /// Enables multi-threaded chunk encoding via isolate workers.
  static const bool kChunkEncodingUseIsolates = true;

  /// Max encoded chunks cached per dimension.
  static const int kMaxEncodedChunkCache = 2048;
}
