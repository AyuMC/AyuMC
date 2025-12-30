import 'package:flutter/material.dart';

import '../../../../../core/theme/app_text_styles.dart';
import '../../../domain/entities/server_status.dart';
import '../../utils/server_status_extensions.dart';
import 'status_indicator_builder.dart';
import 'status_uptime_builder.dart';

class StatusCardContentBuilder {
  StatusCardContentBuilder._();

  static Widget build(ServerStatus status) {
    return Row(
      children: [
        StatusIndicatorBuilder.build(status.type),
        const SizedBox(width: 24),
        Expanded(child: _buildStatusInfo(status)),
        StatusUptimeBuilder.build(),
      ],
    );
  }

  static Widget _buildStatusInfo(ServerStatus status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Server Status', style: AppTextStyles.h3),
        const SizedBox(height: 8),
        Text(
          status.type.displayText,
          style: AppTextStyles.h4.copyWith(color: status.type.color),
        ),
      ],
    );
  }
}
