import 'package:ayu_core/ayu_core.dart';
import 'package:ayu_core/events/server_started_event.dart';

void main() async {
  final server = AyuServer();

  server.events.listen<ServerStartedEvent>((event) {
    print('SERVER START EVENT RECEIVED!');
  });
  await server.start();

  server.commands.execute('ping');
  server.commands.execute('say hello world');

  await Future.delayed(Duration(seconds: 3));

  await server.stop();
}
