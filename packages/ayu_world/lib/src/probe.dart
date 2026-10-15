import 'dart:async';

import 'budgets.dart';

/// Loop-delay probe. There is no gameplay tick, so lateness of this 100ms
/// timer is the engine-responsiveness signal.
final class ResponsivenessProbe {
  ResponsivenessProbe({this.period = const Duration(milliseconds: 100)});

  final Duration period;

  Pressure pressure = Pressure.normal;
  int lastLatenessMicros = 0;
  int ticks = 0;

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  int _nextDue = 0;
  int _highStreak = 0;
  int _lowStreak = 0;

  void start() {
    if (_timer != null) return;
    _clock
      ..reset()
      ..start();
    _nextDue = period.inMicroseconds;
    _timer = Timer.periodic(period, (_) => record());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Called by the timer, or by tests.
  void record() {
    ticks++;
    if (!_clock.isRunning) _clock.start();
    final now = _clock.elapsedMicroseconds;
    var late = now - _nextDue;
    if (late < 0) late = 0;
    lastLatenessMicros = late;
    _nextDue += period.inMicroseconds;
    if (now > _nextDue + period.inMicroseconds) {
      _nextDue = now + period.inMicroseconds;
    }
    if (late > 50000) {
      pressure = Pressure.critical;
      _highStreak++;
      _lowStreak = 0;
    } else if (late > 20000) {
      _highStreak++;
      _lowStreak = 0;
      if (_highStreak >= 3) pressure = Pressure.degraded;
    } else if (late < 5000) {
      _lowStreak++;
      _highStreak = 0;
      if (_lowStreak >= 10) pressure = Pressure.normal;
    } else {
      _highStreak = 0;
      _lowStreak = 0;
    }
  }
}
