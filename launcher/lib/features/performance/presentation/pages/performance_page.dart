import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';

class PerformancePage extends StatelessWidget {
  const PerformancePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.speed, size: 64),
          SizedBox(height: 16),
          Text('Performance', style: AppTextStyles.h2),
          SizedBox(height: 8),
          Text('Server performance metrics', style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}
