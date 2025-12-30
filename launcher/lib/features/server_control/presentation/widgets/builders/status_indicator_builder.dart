import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../domain/entities/server_status.dart';
import '../../utils/server_status_extensions.dart';

class StatusIndicatorBuilder {
  StatusIndicatorBuilder._();

  static Widget build(ServerStatusType type) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: 80,
          height: 80,
          decoration: _buildDecoration(type),
          child: _buildIcon(type),
        ),
      ),
    );
  }

  static BoxDecoration _buildDecoration(ServerStatusType type) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [type.color.withOpacity(0.2), type.color.withOpacity(0.1)],
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: type.color.withOpacity(0.4), width: 2),
      boxShadow: [
        BoxShadow(
          color: type.color.withOpacity(0.3),
          blurRadius: 20,
          spreadRadius: 2,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  static Widget _buildIcon(ServerStatusType type) {
    return Icon(type.icon, size: 40, color: type.color);
  }
}
