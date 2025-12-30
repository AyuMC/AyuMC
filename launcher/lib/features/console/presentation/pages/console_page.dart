import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../domain/repositories/log_repository.dart';
import '../bloc/console_bloc.dart';
import '../bloc/console_event.dart';
import '../bloc/console_state.dart';
import '../widgets/builders/console_toolbar_builder.dart';
import '../widgets/builders/log_item_builder.dart';

/// Console page for displaying server logs in real-time.
///
/// Features auto-scrolling, filtering, and searching capabilities.
class ConsolePage extends StatefulWidget {
  final LogRepository logRepository;

  const ConsolePage({super.key, required this.logRepository});

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          ConsoleBloc(logRepository: widget.logRepository)
            ..add(const ConsoleStartListening()),
      child: BlocBuilder<ConsoleBloc, ConsoleState>(
        builder: (context, state) {
          _scrollToBottomIfNeeded();
          return _buildConsoleContent(context, state);
        },
      ),
    );
  }

  Widget _buildConsoleContent(BuildContext context, ConsoleState state) {
    return Column(
      children: [
        _buildToolbar(context, state),
        Expanded(child: _buildLogsList(state)),
        _buildStatusBar(state),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, ConsoleState state) {
    return ConsoleToolbarBuilder.build(
      onClear: () => context.read<ConsoleBloc>().add(const ConsoleClearLogs()),
      onFilterChanged: (level) =>
          context.read<ConsoleBloc>().add(ConsoleFilterByLevel(level)),
      onSearch: (query) =>
          context.read<ConsoleBloc>().add(ConsoleSearchLogs(query)),
      currentFilter: state.filterLevel,
    );
  }

  Widget _buildLogsList(ConsoleState state) {
    final logsToDisplay =
        state.searchQuery.isNotEmpty || state.filterLevel != null
        ? state.filteredLogs
        : state.logs;

    if (logsToDisplay.isEmpty) {
      return _buildEmptyState();
    }

    return Container(
      color: Colors.black,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: logsToDisplay.length,
        itemBuilder: (context, index) {
          return LogItemBuilder.build(logsToDisplay[index]);
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text(
        'No logs yet. Start the server to see logs.',
        style: TextStyle(color: Colors.grey),
      ),
    );
  }

  Widget _buildStatusBar(ConsoleState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(top: BorderSide(color: Colors.grey[800]!, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${state.logs.length} logs',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          Row(
            children: [
              Checkbox(
                value: _autoScroll,
                onChanged: (value) {
                  setState(() {
                    _autoScroll = value ?? true;
                  });
                },
              ),
              const Text(
                'Auto-scroll',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _scrollToBottomIfNeeded() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }
}
