import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/widgets/glass_container.dart';
import '../bloc/server_bloc.dart';
import '../bloc/server_state.dart';
import 'builders/status_card_content_builder.dart';
import 'builders/status_loading_builder.dart';

class ServerStatusCard extends StatelessWidget {
  const ServerStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      blur: 15,
      opacity: 0.15,
      padding: const EdgeInsets.all(24),
      child: BlocBuilder<ServerBloc, ServerState>(
        builder: (context, state) {
          if (state is ServerSuccess) {
            return StatusCardContentBuilder.build(state.status);
          }
          return StatusLoadingBuilder.build();
        },
      ),
    );
  }
}
