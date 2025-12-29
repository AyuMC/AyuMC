enum ServerState { stopped, starting, running, stopping, restarting }

class AyuMCServer {
  static ServerState state = ServerState.stopped;

  static Future<void> start() async {
    state = ServerState.starting;
    print('Starting AyuMC Server...');
  }

  static Future<void> stop() async {
    state = ServerState.stopping;
    print('Stopping AyuMC Server...');
  }

  static Future<void> restart() async {
    state = ServerState.restarting;
    print('Restarting AyuMC Server...');
  }
}
