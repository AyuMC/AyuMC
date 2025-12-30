/// Minecraft protocol version numbers.
///
/// Maps game versions to their protocol version numbers.
class ProtocolVersion {
  ProtocolVersion._();

  /// Protocol version for Minecraft 1.20.4
  static const int v1_20_4 = 765;

  /// Protocol version for Minecraft 1.21.1
  static const int v1_21_1 = 800;

  /// Protocol version for Minecraft 1.21
  static const int v1_21 = 799;

  /// Protocol version for Minecraft 1.20.6
  static const int v1_20_6 = 766;

  /// Protocol version for Minecraft 1.20.1
  static const int v1_20_1 = 763;

  /// Protocol version for Minecraft 1.19.4
  static const int v1_19_4 = 762;

  /// Protocol version for Minecraft 1.8
  static const int v1_8 = 47;

  /// Default protocol version (1.20.4)
  static const int kDefault = v1_20_4;

  /// Converts protocol version number to game version string.
  static String toGameVersion(int protocolVersion) {
    switch (protocolVersion) {
      case v1_21_1:
        return '1.21.1';
      case v1_21:
        return '1.21';
      case v1_20_6:
        return '1.20.6';
      case v1_20_4:
        return '1.20.4';
      case v1_20_1:
        return '1.20.1';
      case v1_19_4:
        return '1.19.4';
      case v1_8:
        return '1.8';
      default:
        return 'Unknown ($protocolVersion)';
    }
  }

  /// Checks if protocol version is supported.
  static bool isSupported(int protocolVersion) {
    return protocolVersion >= v1_8 && protocolVersion <= v1_21_1;
  }
}
