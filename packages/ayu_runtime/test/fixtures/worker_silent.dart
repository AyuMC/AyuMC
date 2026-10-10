// Test worker: stays alive indefinitely and never speaks the protocol.
// A timer keeps the event loop alive; a bare pending Future would let the
// VM exit as soon as main() returns.
import 'dart:async';

void main() {
  Timer.periodic(const Duration(hours: 1), (_) {});
}
