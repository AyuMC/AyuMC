import 'package:flutter/material.dart';
import '../../domain/entities/server_status.dart';

extension ServerStatusTypeExtensions on ServerStatusType {
  IconData get icon {
    switch (this) {
      case ServerStatusType.stopped:
        return Icons.stop_circle;
      case ServerStatusType.starting:
        return Icons.play_circle_outline;
      case ServerStatusType.running:
        return Icons.check_circle;
      case ServerStatusType.stopping:
        return Icons.pause_circle;
      case ServerStatusType.error:
        return Icons.error;
    }
  }

  Color get color {
    switch (this) {
      case ServerStatusType.stopped:
        return Colors.grey;
      case ServerStatusType.starting:
        return Colors.orange;
      case ServerStatusType.running:
        return Colors.green;
      case ServerStatusType.stopping:
        return Colors.orange;
      case ServerStatusType.error:
        return Colors.red;
    }
  }

  String get displayText {
    switch (this) {
      case ServerStatusType.stopped:
        return 'Stopped';
      case ServerStatusType.starting:
        return 'Starting...';
      case ServerStatusType.running:
        return 'Running';
      case ServerStatusType.stopping:
        return 'Stopping...';
      case ServerStatusType.error:
        return 'Error';
    }
  }
}

