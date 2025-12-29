enum ServerState { stopped, starting, running, stopping, restarting }

class AyuMCServer {
  static ServerState state = ServerState.stopped;

  static Future<void> start() async {
    state = ServerState.starting;
    print('Starting AyuMC Server...');
    await Future.delayed(const Duration(seconds: 2));
    state = ServerState.running;
    print('AyuMC Server started');
  }

  static Future<void> stop() async {
    state = ServerState.stopping;
    print('Stopping AyuMC Server...');
    await Future.delayed(const Duration(seconds: 2));
    state = ServerState.stopped;
    print('AyuMC Server stopped');
  }

  static Future<void> restart() async {
    state = ServerState.restarting;
    print('Restarting AyuMC Server...');
    await Future.delayed(const Duration(seconds: 2));
    state = ServerState.running;
    print('AyuMC Server restarted');
  }
}
