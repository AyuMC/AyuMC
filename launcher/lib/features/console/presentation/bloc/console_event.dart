import 'package:equatable/equatable.dart';

import '../../domain/entities/server_log.dart';

/// Base class for all console events.
abstract class ConsoleEvent extends Equatable {
  const ConsoleEvent();

  @override
  List<Object?> get props => [];
}

/// Event to start listening to server logs.
class ConsoleStartListening extends ConsoleEvent {
  const ConsoleStartListening();
}

/// Event triggered when a new log is received.
class ConsoleLogReceived extends ConsoleEvent {
  final ServerLog log;

  const ConsoleLogReceived(this.log);

  @override
  List<Object?> get props => [log];
}

/// Event to clear all logs.
class ConsoleClearLogs extends ConsoleEvent {
  const ConsoleClearLogs();
}

/// Event to filter logs by level.
class ConsoleFilterByLevel extends ConsoleEvent {
  final LogLevel? level;

  const ConsoleFilterByLevel(this.level);

  @override
  List<Object?> get props => [level];
}

/// Event to search logs by text.
class ConsoleSearchLogs extends ConsoleEvent {
  final String query;

  const ConsoleSearchLogs(this.query);

  @override
  List<Object?> get props => [query];
}
