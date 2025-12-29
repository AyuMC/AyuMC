import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/repositories/server_repository_impl.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_state.dart';
import '../widgets/start_server_button.dart';
import '../widgets/stop_server_button.dart';
import '../widgets/server_status_indicator.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text(AppConstants.appName)),
      body: BlocListener<ServerBloc, ServerState>(
        listener: (context, state) {
          if (state is ServerFailure) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ServerStatusIndicator(),
              SizedBox(height: 32),
              StartServerButton(),
              SizedBox(height: 16),
              StopServerButton(),
            ],
          ),
        ),
      ),
    );
  }
}
