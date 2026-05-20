import 'package:ayu_core/ayu_core.dart';

void main() async {
  final server = AyuServer();

  await server.start();

  server.commands.execute('ping');
  server.commands.execute('ayu');
  server.commands.execute('say hello world');

  await Future.delayed(Duration(seconds: 3));

  await server.stop();
}
