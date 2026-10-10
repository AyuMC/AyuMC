import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_package/ayu_package.dart';

/// Deadlines and limits of the plugin host. Every wait in the runtime is
/// bounded by one of these values.
final class PluginRuntimeOptions {
  const PluginRuntimeOptions({
    this.helloTimeout = const Duration(seconds: 10),
    this.initTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 5),
    this.commandTimeout = const Duration(seconds: 10),
    this.shutdownGracePeriod = const Duration(seconds: 5),
    this.killTimeout = const Duration(seconds: 5),
    this.maxFrameBytes = 1 << 20,
    this.maxPendingRequests = 256,
    this.outboundHighWatermarkBytes = 4 << 20,
    this.stderrTailBytes = 64 << 10,
    this.restartOnCrash = true,
    this.maxRestarts = 3,
    this.restartWindow = const Duration(minutes: 1),
    this.packageLimits = const PackageLimits(),
  });

  /// Process start until the worker's `hello` request.
  final Duration helloTimeout;

  /// `init` request until the plugin's `onEnable` completed.
  final Duration initTimeout;

  /// Default for host -> worker requests.
  final Duration requestTimeout;

  /// Deadline for a single command execution inside the worker.
  final Duration commandTimeout;

  /// Time a worker gets to finish `onDisable` and exit on its own.
  final Duration shutdownGracePeriod;

  /// Time to wait for the OS to report the exit after a kill.
  final Duration killTimeout;

  final int maxFrameBytes;
  final int maxPendingRequests;
  final int outboundHighWatermarkBytes;

  /// Bytes of worker stderr retained for diagnostics.
  final int stderrTailBytes;

  /// Restart a plugin whose worker exited unexpectedly while active.
  final bool restartOnCrash;

  /// Restarts allowed per plugin within [restartWindow] before it is left
  /// in the crashed state.
  final int maxRestarts;
  final Duration restartWindow;

  final PackageLimits packageLimits;

  ChannelOptions get channelOptions => ChannelOptions(
        maxFrameBytes: maxFrameBytes,
        defaultRequestTimeout: requestTimeout,
        maxPendingRequests: maxPendingRequests,
        outboundHighWatermarkBytes: outboundHighWatermarkBytes,
      );
}
