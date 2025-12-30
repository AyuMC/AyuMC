import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

class NavigationTabDecorationBuilder {
  NavigationTabDecorationBuilder._();

  static BoxDecoration build(bool isSelected) {
    if (!isSelected) {
      return const BoxDecoration();
    }

    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.primary.withOpacity(0.1),
          AppColors.primaryDark.withOpacity(0.05),
        ],
      ),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.primary.withOpacity(0.3), width: 1),
      boxShadow: [
        BoxShadow(
          color: AppColors.primary.withOpacity(0.2),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  static Color getTextColor(bool isSelected) {
    return isSelected ? AppColors.primary : AppColors.textSecondary;
  }
}
