class NetworkConstants {
  NetworkConstants._();

  static const int defaultPort = 25565;
  static const String defaultHost = '0.0.0.0';
  static const int maxPacketSize = 2097152;
  static const Duration connectionTimeout = Duration(seconds: 30);
}
