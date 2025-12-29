import 'package:equatable/equatable.dart';
import '../../domain/entities/server_status.dart';

abstract class ServerState extends Equatable {
  const ServerState();

  @override
  List<Object?> get props => [];
}

class ServerInitial extends ServerState {
  const ServerInitial();
}

class ServerLoading extends ServerState {
  const ServerLoading();
}

class ServerSuccess extends ServerState {
  final ServerStatus status;

  const ServerSuccess(this.status);

  @override
  List<Object?> get props => [status];
}

class ServerFailure extends ServerState {
  final String message;

  const ServerFailure(this.message);

  @override
  List<Object?> get props => [message];
}

