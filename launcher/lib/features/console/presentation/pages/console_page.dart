import 'package:flutter/material.dart';
import '../../../../core/theme/app_text_styles.dart';

class ConsolePage extends StatelessWidget {
  const ConsolePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 64),
          SizedBox(height: 16),
          Text('Console', style: AppTextStyles.h2),
          SizedBox(height: 8),
          Text('Execute server commands here', style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}
