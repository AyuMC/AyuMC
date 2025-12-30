import 'package:flutter/material.dart';
import '../../../../core/theme/app_text_styles.dart';

class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.article, size: 64),
          SizedBox(height: 16),
          Text('Logs', style: AppTextStyles.h2),
          SizedBox(height: 8),
          Text('Server logs will appear here', style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}
