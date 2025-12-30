import 'dart:async';

/// An adaptive performance scheduler that dynamically adjusts tick rate.
///
/// The [PerformanceAdaptiveScheduler] monitors server load and automatically
/// adjusts the tick rate to optimize performance. It uses a smooth transition
/// algorithm to prevent oscillation.
///
/// Example:
/// ```dart
/// final scheduler = PerformanceAdaptiveScheduler();
/// scheduler.start();
///
/// scheduler.recordLoad(cpuUsage);
/// print('Current tick rate: ${scheduler.currentTickRate}');
/// ```
class PerformanceAdaptiveScheduler {
  static const int kMinTickRate = 10;
  static const int kMaxTickRate = 100;
  static const int kDefaultTickRate = 50;
  static const int kAdjustmentIntervalMs = 1000;
  static const int kLoadHistorySize = 10;

  int _currentTickRate = kDefaultTickRate;
  int _targetTickRate = kDefaultTickRate;
  Timer? _adjustmentTimer;
  final List<double> _loadHistory = [];

  /// Starts the adaptive scheduler.
  void start() {
    _adjustmentTimer = Timer.periodic(
      const Duration(milliseconds: kAdjustmentIntervalMs),
      (_) => _adjustTickRate(),
    );
  }

  /// Records a load sample for adaptive adjustment.
  ///
  /// Load should be a value between 0.0 (idle) and 1.0 (full load).
  void recordLoad(double load) {
    _loadHistory.add(load.clamp(0.0, 1.0));

    if (_loadHistory.length > kLoadHistorySize) {
      _loadHistory.removeAt(0);
    }
  }

  void _adjustTickRate() {
    if (_loadHistory.isEmpty) return;

    final avgLoad = _calculateAverageLoad();
    _targetTickRate = _calculateOptimalTickRate(avgLoad);

    _smoothTransition();
  }

  double _calculateAverageLoad() {
    return _loadHistory.reduce((a, b) => a + b) / _loadHistory.length;
  }

  int _calculateOptimalTickRate(double load) {
    if (load < 0.3) {
      return kMinTickRate;
    } else if (load < 0.6) {
      return (kDefaultTickRate * 0.7).round();
    } else if (load < 0.8) {
      return kDefaultTickRate;
    } else {
      return kMaxTickRate;
    }
  }

  void _smoothTransition() {
    final diff = _targetTickRate - _currentTickRate;
    final step = (diff * 0.3).round();

    if (step != 0) {
      _currentTickRate += step;
      _currentTickRate = _currentTickRate.clamp(kMinTickRate, kMaxTickRate);
    }
  }

  /// Returns the current tick rate in ticks per second.
  int get currentTickRate => _currentTickRate;

  /// Returns the duration of one tick at the current tick rate.
  Duration get tickDuration => Duration(milliseconds: 1000 ~/ _currentTickRate);

  /// Stops the adaptive scheduler and clears load history.
  void stop() {
    _adjustmentTimer?.cancel();
    _loadHistory.clear();
  }
}
