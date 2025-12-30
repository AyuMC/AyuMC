import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/entities/server_log.dart';
import '../bloc/console_bloc.dart';
import '../bloc/console_event.dart';
import '../bloc/console_state.dart';
import '../widgets/builders/console_content_builder.dart';
import '../widgets/builders/console_status_bar_builder.dart';
import '../widgets/builders/console_toolbar_builder.dart';
import '../utils/console_scroll_manager.dart';

/// Console page for displaying server logs in real-time.
///
/// Clean, professional implementation with separated concerns.
/// All logic is managed by BLoC, UI is purely presentational.
class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key});

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  late final ConsoleScrollManager _scrollManager;

  @override
  void initState() {
    super.initState();
    _scrollManager = ConsoleScrollManager();
  }

  @override
  void dispose() {
    _scrollManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ConsoleBloc, ConsoleState>(
      listener: (context, state) {
        _scrollManager.handleNewLogs(state.logs.length);
      },
      builder: (context, state) {
        final logsToDisplay = _getDisplayedLogs(state);
        return Column(
          children: [
            ConsoleToolbarBuilder.build(
              onFilterChanged: (level) =>
                  context.read<ConsoleBloc>().add(ConsoleFilterByLevel(level)),
              onSearch: (query) =>
                  context.read<ConsoleBloc>().add(ConsoleSearchLogs(query)),
              currentFilter: state.filterLevel,
            ),
            Expanded(
              child: ConsoleContentBuilder.buildLogsList(
                logs: logsToDisplay,
                scrollController: _scrollManager.scrollController,
              ),
            ),
            ConsoleStatusBarBuilder.build(
              logCount: state.logs.length,
              autoScroll: _scrollManager.autoScroll,
              onAutoScrollChanged: _scrollManager.setAutoScroll,
            ),
          ],
        );
      },
    );
  }

  List<ServerLog> _getDisplayedLogs(ConsoleState state) {
    return state.searchQuery.isNotEmpty || state.filterLevel != null
        ? state.filteredLogs
        : state.logs;
  }
}
