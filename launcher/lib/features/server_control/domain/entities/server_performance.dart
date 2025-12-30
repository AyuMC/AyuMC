class ServerPerformance {
  final int connectionsActive;
  final int packetsPerSecond;
  final double bytesPerSecond;
  final double averageLoad;
  final int tickRate;
  final List<int> workerLoads;

  const ServerPerformance({
    required this.connectionsActive,
    required this.packetsPerSecond,
    required this.bytesPerSecond,
    required this.averageLoad,
    required this.tickRate,
    required this.workerLoads,
  });

  factory ServerPerformance.empty() {
    return const ServerPerformance(
      connectionsActive: 0,
      packetsPerSecond: 0,
      bytesPerSecond: 0.0,
      averageLoad: 0.0,
      tickRate: 0,
      workerLoads: [],
    );
  }

  String get formattedBytesPerSecond {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(1)} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }

  double get loadPercentage => (averageLoad * 100).clamp(0.0, 100.0);
}
