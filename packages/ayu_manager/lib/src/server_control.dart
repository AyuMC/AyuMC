import 'dart:async';
import 'dart:io';

import 'package:ayu_core/ayu_core.dart';

enum ServerRunState { stopped, starting, running, stopping, failed }

/// Owns one in-process [AyuServer]. A second start is refused while one is active.
final class ServerControl {
  ServerControl({
    required this.root,
    this.shutdownTimeout = const Duration(seconds: 20),
  });

  final Directory root;
  final Duration shutdownTimeout;

  AyuServer? server;
  ServerRunState state = ServerRunState.stopped;
  String? lastError;
  DateTime? startedAt;
  int? listeningPort;

  bool get isBusy =>
      state == ServerRunState.starting || state == ServerRunState.stopping;

  Future<String> start() async {
    if (state == ServerRunState.running || state == ServerRunState.starting) {
      return 'server is already $state';
    }
    state = ServerRunState.starting;
    lastError = null;
    final next = AyuServer(rootDirectory: root);
    try {
      await next.start();
    } catch (error) {
      state = ServerRunState.failed;
      lastError = '$error';
      server = null;
      return 'start failed: $error';
    }
    server = next;
    startedAt = DateTime.now();
    listeningPort = next.network?.port;
    state = next.network == null
        ? ServerRunState.failed
        : ServerRunState.running;
    if (next.network == null) {
      lastError =
          'Minecraft listener did not bind. Another process may own the port.';
      return lastError!;
    }
    return 'running on port $listeningPort';
  }

  Future<String> stop() async {
    final current = server;
    if (current == null || state == ServerRunState.stopped)
      return 'server is stopped';
    if (state == ServerRunState.stopping) return 'stop already in progress';
    state = ServerRunState.stopping;
    try {
      await current.stop().timeout(shutdownTimeout);
      state = ServerRunState.stopped;
      server = null;
      listeningPort = null;
      return 'stopped';
    } on TimeoutException {
      state = ServerRunState.failed;
      lastError =
          'shutdown exceeded ${shutdownTimeout.inSeconds}s. Close this manager only after checking for leftover dartaotruntime processes.';
      return lastError!;
    } catch (error) {
      state = ServerRunState.failed;
      lastError = '$error';
      return 'stop failed: $error';
    }
  }

  Future<String> restart() async {
    if (state == ServerRunState.running) {
      final stopped = await stop();
      if (state != ServerRunState.stopped) return stopped;
    }
    return start();
  }
}
