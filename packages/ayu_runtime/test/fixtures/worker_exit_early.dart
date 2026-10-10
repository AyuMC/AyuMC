// Test worker: dies before the handshake with a diagnostic on stderr.
import 'dart:io';

void main() {
  stderr.writeln('fixture refuses to start');
  exit(7);
}
