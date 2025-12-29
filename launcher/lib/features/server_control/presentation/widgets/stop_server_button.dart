import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_event.dart';
import '../bloc/server_state.dart';
import '../utils/button_helpers.dart';
import '../utils/server_state_extensions.dart';

class StopServerButton extends StatelessWidget {
  const StopServerButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ServerBloc, ServerState>(
      builder: (context, state) {
        final isLoading = state.isLoading;
        final isStopped = state.isStopped;

        return ElevatedButton.icon(
          onPressed: isLoading || isStopped
              ? null
              : () =>
                    context.read<ServerBloc>().add(const ServerStopRequested()),
          icon: ButtonHelpers.buildStopIcon(context, isLoading),
          label: Text(ButtonHelpers.getStopButtonText(isLoading)),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            minimumSize: const Size(200, 48),
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
        );
      },
    );
  }
}
