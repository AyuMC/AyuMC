import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_state.dart';
import '../utils/server_status_extensions.dart';

class ServerStatusIndicator extends StatelessWidget {
  const ServerStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ServerBloc, ServerState>(
      builder: (context, state) {
        if (state is ServerSuccess) {
          return Column(
            children: [
              Icon(
                state.status.type.icon,
                size: 64,
                color: state.status.type.color,
              ),
              const SizedBox(height: 16),
              Text(
                state.status.type.displayText,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          );
        }

        if (state is ServerLoading) {
          return const Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading...'),
            ],
          );
        }

        return const Text('Unknown status');
      },
    );
  }
}

