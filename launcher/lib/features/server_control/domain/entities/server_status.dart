import 'package:equatable/equatable.dart';

enum ServerStatusType { stopped, starting, running, stopping, error }

class ServerStatus extends Equatable {
  final ServerStatusType type;
  final String? message;

  const ServerStatus({required this.type, this.message});

  const ServerStatus.stopped() : this(type: ServerStatusType.stopped);
  const ServerStatus.starting() : this(type: ServerStatusType.starting);
  const ServerStatus.running() : this(type: ServerStatusType.running);
  const ServerStatus.stopping() : this(type: ServerStatusType.stopping);
  const ServerStatus.error(String message)
    : this(type: ServerStatusType.error, message: message);

  @override
  List<Object?> get props => [type, message];
}
