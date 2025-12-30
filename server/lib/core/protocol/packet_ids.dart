/// Minecraft protocol packet IDs for different connection states.
class PacketIds {
  PacketIds._();

  /// Handshake packets (serverbound)
  static const int handshakeHandshake = 0x00;

  /// Status packets (serverbound)
  static const int statusRequest = 0x00;
  static const int statusPing = 0x01;

  /// Status packets (clientbound)
  static const int statusResponse = 0x00;
  static const int statusPong = 0x01;

  /// Login packets (serverbound)
  static const int loginStart = 0x00;
  static const int loginEncryptionResponse = 0x01;
  static const int loginPluginResponse = 0x02;

  /// Login packets (clientbound)
  static const int loginDisconnect = 0x00;
  static const int loginEncryptionRequest = 0x01;
  static const int loginSuccess = 0x02;
  static const int loginCompression = 0x03;
  static const int loginPluginRequest = 0x04;

  /// Play packets - Clientbound (server to client)
  static const int playJoinGame = 0x28;
  static const int playKeepAliveClientbound = 0x27;
  static const int playDisconnect = 0x1D;
  static const int playPlayerPosition = 0x40;
  static const int playSetDefaultSpawnPosition = 0x56;
  static const int playGameEvent = 0x22;

  /// Play packets - Serverbound (client to server)
  static const int playKeepAliveServerbound = 0x18;
  static const int playPlayerPositionServerbound = 0x1A;
  static const int playChatMessage = 0x06;
}
