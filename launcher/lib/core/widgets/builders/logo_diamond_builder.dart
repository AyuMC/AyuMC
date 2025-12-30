import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

class LogoDiamondBuilder {
  LogoDiamondBuilder._();

  static Widget build(double size) {
    return Container(
      width: size,
      height: size,
      decoration: _buildDecoration(),
      child: _buildIcon(),
    );
  }

  static BoxDecoration _buildDecoration() {
    return BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.primary, AppColors.primaryDark],
      ),
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: AppColors.primary.withOpacity(0.5),
          blurRadius: 20,
          spreadRadius: 2,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  static Widget _buildIcon() {
    return const Icon(Icons.diamond, color: Colors.white, size: 32);
  }
}
