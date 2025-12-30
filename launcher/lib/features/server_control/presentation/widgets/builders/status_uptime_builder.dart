import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_text_styles.dart';

class StatusUptimeBuilder {
  StatusUptimeBuilder._();

  static Widget build() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text('Uptime', style: AppTextStyles.label),
        const SizedBox(height: 4),
        Text(
          '0h 0m',
          style: AppTextStyles.h4.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
