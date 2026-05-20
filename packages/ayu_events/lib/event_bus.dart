import 'package:ayu_logging/ayu_logging.dart';

import 'event.dart';
import 'event_listener.dart';

class EventBus {
  final Logger logger = Logger('Events');

  final Map<Type, List<dynamic>> _listeners = {};

  void listen<T extends Event>(EventListener<T> listener) {
    _listeners.putIfAbsent(T, () => []);

    _listeners[T]!.add(listener);

    logger.info('Registered listener for ${T.toString()}');
  }

  void emit<T extends Event>(T event) {
    final listeners = _listeners[T];

    if (listeners == null) return;

    logger.info('Emitting ${T.toString()}');

    for (final listener in listeners) {
      (listener as EventListener<T>)(event);
    }
  }
}
