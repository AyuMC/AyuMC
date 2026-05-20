import 'lifecycle.dart';
import 'states.dart';

class AyuServer {
  final ServerLifecycle lifecycle = ServerLifecycle();

  Future<void> start() async {
    lifecycle.setState(ServerState.starting);

    await Future.delayed(Duration(seconds: 1));

    lifecycle.setState(ServerState.running);
  }

  Future<void> stop() async {
    lifecycle.setState(ServerState.stopping);

    await Future.delayed(Duration(seconds: 1));

    lifecycle.setState(ServerState.stopped);
  }
}
