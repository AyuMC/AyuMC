import 'package:ayu_core/ayu_core.dart';

void main() async {
  final server = AyuServer();

  await server.start();

  await Future.delayed(Duration(seconds: 3));

  await server.stop();
}
