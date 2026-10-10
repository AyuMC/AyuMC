// Test worker: corrupts the protocol stream with arbitrary bytes and then
// stays alive, like a plugin that wrote to stdout directly.
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  stdout.add(List<int>.generate(4096, (i) => 0xFF - (i & 0x7F)));
  await stdout.flush();
  Timer.periodic(const Duration(hours: 1), (_) {});
}
