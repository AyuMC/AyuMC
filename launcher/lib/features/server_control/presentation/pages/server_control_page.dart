import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/repositories/server_repository_impl.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_state.dart';
import '../widgets/server_control_panel.dart';
import '../widgets/server_status_card.dart';

class ServerControlPage extends StatelessWidget {
  const ServerControlPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => ServerBloc(repository: ServerRepositoryImpl()),
      child: const ServerControlView(),
    );
  }
}

class ServerControlView extends StatelessWidget {
  const ServerControlView({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocListener<ServerBloc, ServerState>(
      listener: (context, state) {
        if (state is ServerFailure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ServerStatusCard(),
            SizedBox(height: 24),
            ServerControlPanel(),
          ],
        ),
      ),
    );
  }
}
