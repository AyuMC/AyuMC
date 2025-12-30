import 'package:flutter/material.dart';
import '../../../../core/theme/app_text_styles.dart';

class PlayersPage extends StatelessWidget {
  const PlayersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people, size: 64),
          SizedBox(height: 16),
          Text('Players', style: AppTextStyles.h2),
          SizedBox(height: 8),
          Text(
            'Connected players will appear here',
            style: AppTextStyles.bodyMedium,
          ),
        ],
      ),
    );
  }
}
