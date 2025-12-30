import 'dart:ui';
import 'package:flutter/material.dart';

class ControlButtonBuilder {
  ControlButtonBuilder._();

  static Widget build({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
          style: _buildButtonStyle(color),
        ),
      ),
    );
  }

  static ButtonStyle _buildButtonStyle(Color color) {
    return ElevatedButton.styleFrom(
      backgroundColor: color.withOpacity(0.8),
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
    ).copyWith(
      overlayColor: WidgetStateProperty.all(Colors.white.withOpacity(0.1)),
    );
  }
}
