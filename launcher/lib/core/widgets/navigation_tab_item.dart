import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_text_styles.dart';
import 'builders/navigation_tab_decoration_builder.dart';

class NavigationTabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const NavigationTabItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: isSelected ? 10 : 0,
          sigmaY: isSelected ? 10 : 0,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            decoration: NavigationTabDecorationBuilder.build(isSelected),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: NavigationTabDecorationBuilder.getTextColor(
                    isSelected,
                  ),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppTextStyles.buttonSmall.copyWith(
                    color: NavigationTabDecorationBuilder.getTextColor(
                      isSelected,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
