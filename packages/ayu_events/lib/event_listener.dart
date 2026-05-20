import 'event.dart';

typedef EventListener<T extends Event> = void Function(T event);
