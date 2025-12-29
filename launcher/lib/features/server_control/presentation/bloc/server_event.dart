import 'package:equatable/equatable.dart';

abstract class ServerEvent extends Equatable {
  const ServerEvent();

  @override
  List<Object?> get props => [];
}

class ServerStartRequested extends ServerEvent {
  const ServerStartRequested();
}

class ServerStopRequested extends ServerEvent {
  const ServerStopRequested();
}

class ServerRestartRequested extends ServerEvent {
  const ServerRestartRequested();
}

class ServerStatusRequested extends ServerEvent {
  const ServerStatusRequested();
}

