import 'package:flutter/material.dart';
import '../../../../core/theme/app_text_styles.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.settings, size: 64),
          SizedBox(height: 16),
          Text('Settings', style: AppTextStyles.h2),
          SizedBox(height: 8),
          Text('Server configuration options', style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}
