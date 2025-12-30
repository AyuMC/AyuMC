/// Real-time network statistics and monitoring.
///
/// The [NetworkPerformanceStatistics] singleton tracks all network metrics
/// including packets, bytes, connections, and load averages. It provides
/// comprehensive insights into server performance.
///
/// Example:
/// ```dart
/// final stats = NetworkPerformanceStatistics();
///
/// stats.recordPacketReceived(packetSize);
/// stats.recordConnectionOpened();
///
/// print('Packets/sec: ${stats.packetsPerSecond}');
/// print('Average load: ${stats.averageLoad}');
/// ```
class NetworkPerformanceStatistics {
  static final NetworkPerformanceStatistics _instance =
      NetworkPerformanceStatistics._internal();

  /// Returns the singleton instance.
  factory NetworkPerformanceStatistics() => _instance;

  NetworkPerformanceStatistics._internal();

  int _packetsReceived = 0;
  int _packetsSent = 0;
  int _bytesReceived = 0;
  int _bytesSent = 0;
  int _connectionsTotal = 0;
  int _connectionsActive = 0;

  DateTime _startTime = DateTime.now();
  final List<double> _loadSamples = [];

  static const int kMaxLoadSamples = 60;

  /// Records a received packet with its size in bytes.
  void recordPacketReceived(int bytes) {
    _packetsReceived++;
    _bytesReceived += bytes;
  }

  /// Records a sent packet with its size in bytes.
  void recordPacketSent(int bytes) {
    _packetsSent++;
    _bytesSent += bytes;
  }

  /// Records a new connection being opened.
  void recordConnectionOpened() {
    _connectionsTotal++;
    _connectionsActive++;
  }

  /// Records a connection being closed.
  void recordConnectionClosed() {
    _connectionsActive--;
  }

  /// Records a load sample for average calculation.
  void recordLoad(double load) {
    _loadSamples.add(load.clamp(0.0, 1.0));

    if (_loadSamples.length > kMaxLoadSamples) {
      _loadSamples.removeAt(0);
    }
  }

  /// Returns the average load across recent samples.
  double get averageLoad {
    if (_loadSamples.isEmpty) return 0.0;
    return _loadSamples.reduce((a, b) => a + b) / _loadSamples.length;
  }

  /// Returns the average packets per second since tracking started.
  double get packetsPerSecond {
    final elapsed = DateTime.now().difference(_startTime).inSeconds;
    return elapsed > 0 ? (_packetsReceived + _packetsSent) / elapsed : 0.0;
  }

  /// Returns the average bytes per second since tracking started.
  double get bytesPerSecond {
    final elapsed = DateTime.now().difference(_startTime).inSeconds;
    return elapsed > 0 ? (_bytesReceived + _bytesSent) / elapsed : 0.0;
  }

  /// Returns all statistics as a map for easy serialization.
  Map<String, dynamic> toMap() {
    return {
      'packetsReceived': _packetsReceived,
      'packetsSent': _packetsSent,
      'bytesReceived': _bytesReceived,
      'bytesSent': _bytesSent,
      'connectionsTotal': _connectionsTotal,
      'connectionsActive': _connectionsActive,
      'averageLoad': averageLoad,
      'packetsPerSecond': packetsPerSecond,
      'bytesPerSecond': bytesPerSecond,
    };
  }

  /// Resets all statistics counters and load history.
  void reset() {
    _packetsReceived = 0;
    _packetsSent = 0;
    _bytesReceived = 0;
    _bytesSent = 0;
    _connectionsTotal = 0;
    _connectionsActive = 0;
    _startTime = DateTime.now();
    _loadSamples.clear();
  }
}
