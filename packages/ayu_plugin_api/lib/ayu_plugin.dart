import 'package:ayu_logging/ayu_logging.dart';

abstract class AyuPlugin {
  late final Logger logger;

  void onLoad() {}

  void onEnable() {}

  void onDisable() {}
}
