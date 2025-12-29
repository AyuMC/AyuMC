import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/constants/app_constants.dart';
import '../../domain/entities/server_status.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_event.dart';
import '../bloc/server_state.dart';

class StartServerButton extends StatelessWidget {
  const StartServerButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ServerBloc, ServerState>(
      builder: (context, state) {
        final isLoading = _isLoading(state);
        final isRunning = _isRunning(state);

        return ElevatedButton.icon(
          onPressed: isLoading || isRunning
              ? null
              : () => _onStartPressed(context),
          icon: _buildIcon(isLoading),
          label: Text(_getButtonText(isLoading)),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 16,
            ),
            minimumSize: const Size(200, 48),
          ),
        );
      },
    );
  }

  bool _isLoading(ServerState state) => state is ServerLoading;

  bool _isRunning(ServerState state) {
    return state is ServerSuccess &&
        (state.status.type == ServerStatusType.running ||
            state.status.type == ServerStatusType.starting);
  }

  void _onStartPressed(BuildContext context) {
    context.read<ServerBloc>().add(const ServerStartRequested());
  }

  Widget _buildIcon(bool isLoading) {
    if (isLoading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Icon(Icons.play_arrow);
  }

  String _getButtonText(bool isLoading) {
    return isLoading ? 'Starting...' : AppConstants.serverStartButton;
  }
}

