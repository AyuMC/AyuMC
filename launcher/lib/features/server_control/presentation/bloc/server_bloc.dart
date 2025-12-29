import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/repositories/server_repository.dart';
import 'server_event.dart';
import 'server_state.dart';

class ServerBloc extends Bloc<ServerEvent, ServerState> {
  final ServerRepository _repository;

  ServerBloc({required ServerRepository repository})
    : _repository = repository,
      super(const ServerInitial()) {
    on<ServerStartRequested>(_onServerStartRequested);
    on<ServerStopRequested>(_onServerStopRequested);
    on<ServerRestartRequested>(_onServerRestartRequested);
    on<ServerStatusRequested>(_onServerStatusRequested);

    add(const ServerStatusRequested());
  }

  Future<void> _onServerStartRequested(
    ServerStartRequested event,
    Emitter<ServerState> emit,
  ) async {
    await _handleServerOperation(emit, () => _repository.startServer());
  }

  Future<void> _onServerStopRequested(
    ServerStopRequested event,
    Emitter<ServerState> emit,
  ) async {
    await _handleServerOperation(emit, () => _repository.stopServer());
  }

  Future<void> _onServerRestartRequested(
    ServerRestartRequested event,
    Emitter<ServerState> emit,
  ) async {
    await _handleServerOperation(emit, () => _repository.restartServer());
  }

  Future<void> _handleServerOperation(
    Emitter<ServerState> emit,
    Future<void> Function() operation,
  ) async {
    emit(const ServerLoading());
    try {
      await operation();
      final status = await _repository.getServerStatus().first;
      emit(ServerSuccess(status));
    } catch (e) {
      emit(ServerFailure(e.toString()));
    }
  }

  Future<void> _onServerStatusRequested(
    ServerStatusRequested event,
    Emitter<ServerState> emit,
  ) async {
    try {
      final status = await _repository.getServerStatus().first;
      emit(ServerSuccess(status));
    } catch (e) {
      emit(ServerFailure(e.toString()));
    }
  }
}
