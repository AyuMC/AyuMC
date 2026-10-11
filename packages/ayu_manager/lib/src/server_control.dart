import 'dart:async';
import 'dart:io';

import 'package:ayu_core/ayu_core.dart';

enum ServerRunState { stopped, starting, running, stopping, failed }

/// Starts and stops the server engine. The engine isolate owns sockets,
/// sessions, and plugin workers. This object only keeps a status snapshot
/// and forwards control messages.
final class ServerControl {
  ServerControl({
    required this.root,
    this.shutdownTimeout = const Duration(seconds: 20),
    EngineLink? link,
  }) : _link = link ?? EngineLink(requestTimeout: shutdownTimeout);

  final Directory root;
  final Duration shutdownTimeout;
  final EngineLink _link;

  ServerRunState state = ServerRunState.stopped;
  String? lastError;
  DateTime? startedAt;
  int? listeningPort;
  String? profileId;
  String? runtimeSdk;

  Stream<EngineNotice> get notices => _link.notices;

  bool get isBusy =>
      state == ServerRunState.starting || state == ServerRunState.stopping;

  Future<String> start() async {
    if (state == ServerRunState.running || state == ServerRunState.starting) {
      return 'server is already $state';
    }
    if (state == ServerRunState.failed && _link.isAlive) {
      await stop();
    }
    state = ServerRunState.starting;
    lastError = null;
    try {
      await _link.open();
      final status = await _link.start(root.path);
      return _applyStart(status);
    } on EngineException catch (error) {
      state = ServerRunState.failed;
      lastError = error.message;
      return 'start failed: ${error.message}';
    } catch (error) {
      state = ServerRunState.failed;
      lastError = '$error';
      return 'start failed: $error';
    }
  }

  Future<String> stop() async {
    if (!_link.isAlive || state == ServerRunState.stopped) {
      return 'server is stopped';
    }
    if (state == ServerRunState.stopping) return 'stop already in progress';
    state = ServerRunState.stopping;
    try {
      await _link.stop().timeout(shutdownTimeout);
      state = ServerRunState.stopped;
      listeningPort = null;
      startedAt = null;
      return 'stopped';
    } on TimeoutException {
      state = ServerRunState.failed;
      lastError =
          'shutdown exceeded ${shutdownTimeout.inSeconds}s. Close this manager only after checking for leftover dartaotruntime processes.';
      return lastError!;
    } on EngineException catch (error) {
      state = ServerRunState.failed;
      lastError = error.message;
      return 'stop failed: ${error.message}';
    } catch (error) {
      state = ServerRunState.failed;
      lastError = '$error';
      return 'stop failed: $error';
    }
  }

  Future<String> restart() async {
    if (state == ServerRunState.running || state == ServerRunState.failed) {
      final stopped = await stop();
      if (state != ServerRunState.stopped) return stopped;
    }
    return start();
  }

  Future<void> executeCommand(String line) => _link.command(line);

  Future<List<EnginePackage>> packages() => _link.packages();

  Future<EnginePackage?> package(String id) async {
    for (final item in await packages()) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<EnginePackage> installPackage(
    String path, {
    required bool enable,
    required String id,
  }) {
    return _link.installPackage(path, enable: enable, id: id);
  }

  Future<EnginePackage> enablePackage(String id) => _link.enablePackage(id);

  Future<EnginePackage> disablePackage(String id, {required bool cascade}) {
    return _link.disablePackage(id, cascade: cascade);
  }

  Future<EnginePackage> updatePackage(String path, {required String id}) {
    return _link.updatePackage(path, id: id);
  }

  Future<void> uninstallPackage(String id, {required bool cascade}) {
    return _link.uninstallPackage(id, cascade: cascade);
  }

  Future<Map<String, Object?>> status() => _link.status();

  Future<void> dispose() => _link.dispose();

  String _applyStart(Map<String, Object?> status) {
    final bound = status['state'] == 'running';
    listeningPort = status['port'] as int?;
    profileId = status['profileId'] as String?;
    runtimeSdk = status['runtimeSdk'] as String?;
    final started = status['startedAt'];
    startedAt = started is int
        ? DateTime.fromMillisecondsSinceEpoch(started)
        : DateTime.now();
    if (!bound) {
      state = ServerRunState.failed;
      lastError =
          status['error'] as String? ?? 'Minecraft listener did not bind.';
      return lastError!;
    }
    state = ServerRunState.running;
    lastError = null;
    return 'running on port $listeningPort';
  }
}
