import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/glass_container.dart';
import '../../domain/entities/server_status.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_event.dart';
import '../bloc/server_state.dart';
import 'builders/control_button_builder.dart';

class ServerControlPanel extends StatelessWidget {
  const ServerControlPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      blur: 15,
      opacity: 0.15,
      padding: const EdgeInsets.all(24),
      child: BlocBuilder<ServerBloc, ServerState>(
        builder: (context, state) {
          final isLoading = state is ServerLoading;
          final isRunning = _isServerRunning(state);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Server Control', style: AppTextStyles.h3),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ControlButtonBuilder.build(
                      onPressed: isLoading || isRunning
                          ? null
                          : () => _onStartPressed(context),
                      icon: Icons.play_arrow,
                      label: 'Start Server',
                      color: AppColors.success,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ControlButtonBuilder.build(
                      onPressed: isLoading || !isRunning
                          ? null
                          : () => _onStopPressed(context),
                      icon: Icons.stop,
                      label: 'Stop Server',
                      color: AppColors.error,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ControlButtonBuilder.build(
                onPressed: isLoading || !isRunning
                    ? null
                    : () => _onRestartPressed(context),
                icon: Icons.refresh,
                label: 'Restart Server',
                color: AppColors.warning,
              ),
            ],
          );
        },
      ),
    );
  }

  bool _isServerRunning(ServerState state) {
    return state is ServerSuccess &&
        (state.status.type == ServerStatusType.running ||
            state.status.type == ServerStatusType.starting);
  }

  void _onStartPressed(BuildContext context) {
    context.read<ServerBloc>().add(const ServerStartRequested());
  }

  void _onStopPressed(BuildContext context) {
    context.read<ServerBloc>().add(const ServerStopRequested());
  }

  void _onRestartPressed(BuildContext context) {
    context.read<ServerBloc>().add(const ServerRestartRequested());
  }
}
