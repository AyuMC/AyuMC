import 'package:equatable/equatable.dart';

import '../../domain/entities/server_log.dart';

/// Represents the state of the console.
class ConsoleState extends Equatable {
  final List<ServerLog> logs;
  final List<ServerLog> filteredLogs;
  final LogLevel? filterLevel;
  final String searchQuery;
  final bool isListening;

  const ConsoleState({
    this.logs = const [],
    this.filteredLogs = const [],
    this.filterLevel,
    this.searchQuery = '',
    this.isListening = false,
  });

  ConsoleState copyWith({
    List<ServerLog>? logs,
    List<ServerLog>? filteredLogs,
    LogLevel? filterLevel,
    String? searchQuery,
    bool? isListening,
  }) {
    return ConsoleState(
      logs: logs ?? this.logs,
      filteredLogs: filteredLogs ?? this.filteredLogs,
      filterLevel: filterLevel ?? this.filterLevel,
      searchQuery: searchQuery ?? this.searchQuery,
      isListening: isListening ?? this.isListening,
    );
  }

  @override
  List<Object?> get props => [
    logs,
    filteredLogs,
    filterLevel,
    searchQuery,
    isListening,
  ];
}
