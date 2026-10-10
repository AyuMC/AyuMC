// Test worker: a valid plugin that registers nothing (used as a dependent).
import 'package:ayu_plugin_api/ayu_plugin_api.dart';

void main() => runPlugin(_QuietPlugin());

final class _QuietPlugin extends AyuPlugin {
  @override
  void onEnable() => context.log.info('quiet fixture enabled');
}
