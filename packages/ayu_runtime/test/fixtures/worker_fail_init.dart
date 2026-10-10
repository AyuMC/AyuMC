// Test worker: completes the handshake, then fails in onEnable.
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(_FailingPlugin());

final class _FailingPlugin extends AyuPlugin {
  @override
  void onEnable() => throw StateError('fixture cannot enable');
}
