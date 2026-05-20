import 'states.dart';

class ServerLifecycle {
  ServerState _state = ServerState.stopped;

  ServerState get state => _state;

  void setState(ServerState newState) {
    _state = newState;

    print('[AyuMC - Lifecycle] -> $newState');
  }
}
