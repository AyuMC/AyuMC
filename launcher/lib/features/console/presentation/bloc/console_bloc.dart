import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/server_log.dart';
import '../../domain/repositories/log_repository.dart';
import 'console_event.dart';
import 'console_state.dart';

/// BLoC for managing console state and log filtering.
///
/// Handles log streaming, filtering, and searching with optimal performance.
class ConsoleBloc extends Bloc<ConsoleEvent, ConsoleState> {
  final LogRepository _logRepository;
  StreamSubscription<ServerLog>? _logSubscription;

  ConsoleBloc({required LogRepository logRepository})
    : _logRepository = logRepository,
      super(const ConsoleState()) {
    on<ConsoleStartListening>(_onStartListening);
    on<ConsoleLogReceived>(_onLogReceived);
    on<ConsoleClearLogs>(_onClearLogs);
    on<ConsoleFilterByLevel>(_onFilterByLevel);
    on<ConsoleSearchLogs>(_onSearchLogs);
  }

  Future<void> _onStartListening(
    ConsoleStartListening event,
    Emitter<ConsoleState> emit,
  ) async {
    if (state.isListening) return;

    emit(state.copyWith(isListening: true));

    _logSubscription = _logRepository.getLogStream().listen(
      (log) => add(ConsoleLogReceived(log)),
    );
  }

  void _onLogReceived(ConsoleLogReceived event, Emitter<ConsoleState> emit) {
    final updatedLogs = List<ServerLog>.from(state.logs)..add(event.log);
    final filtered = _applyFilters(updatedLogs);

    emit(state.copyWith(logs: updatedLogs, filteredLogs: filtered));
  }

  void _onClearLogs(ConsoleClearLogs event, Emitter<ConsoleState> emit) {
    _logRepository.clearLogs();
    emit(state.copyWith(logs: [], filteredLogs: []));
  }

  void _onFilterByLevel(
    ConsoleFilterByLevel event,
    Emitter<ConsoleState> emit,
  ) {
    final filtered = _applyFilters(state.logs, levelFilter: event.level);
    emit(state.copyWith(filterLevel: event.level, filteredLogs: filtered));
  }

  void _onSearchLogs(ConsoleSearchLogs event, Emitter<ConsoleState> emit) {
    final filtered = _applyFilters(state.logs, searchQuery: event.query);
    emit(state.copyWith(searchQuery: event.query, filteredLogs: filtered));
  }

  List<ServerLog> _applyFilters(
    List<ServerLog> logs, {
    LogLevel? levelFilter,
    String? searchQuery,
  }) {
    final level = levelFilter ?? state.filterLevel;
    final query = searchQuery ?? state.searchQuery;

    var filtered = logs;

    if (level != null) {
      filtered = filtered.where((log) => log.level == level).toList();
    }

    if (query.isNotEmpty) {
      final lowerQuery = query.toLowerCase();
      filtered = filtered
          .where(
            (log) =>
                log.message.toLowerCase().contains(lowerQuery) ||
                log.source.toLowerCase().contains(lowerQuery),
          )
          .toList();
    }

    return filtered;
  }

  @override
  Future<void> close() {
    _logSubscription?.cancel();
    return super.close();
  }
}
