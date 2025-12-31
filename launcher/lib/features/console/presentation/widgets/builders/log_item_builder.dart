import 'package:flutter/material.dart';

import '../../../domain/entities/server_log.dart';

/// Builder for rendering individual log items.
class LogItemBuilder {
  LogItemBuilder._();

  /// Builds a single log item widget with improved styling.
  static Widget build(ServerLog log) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: _getBackgroundColor(log.level),
        border: Border(
          left: BorderSide(color: Color(log.level.color), width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTimestamp(log.timestamp),
          const SizedBox(width: 12),
          _buildLevelBadge(log.level),
          const SizedBox(width: 12),
          _buildSource(log.source),
          const SizedBox(width: 12),
          Expanded(child: _buildMessage(log.message, log.level)),
        ],
      ),
    );
  }

  static Color _getBackgroundColor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
      case LogLevel.critical:
        return Color(level.color).withOpacity(0.08);
      case LogLevel.warning:
        return Color(level.color).withOpacity(0.06);
      default:
        return Colors.transparent;
    }
  }

  static Widget _buildTimestamp(DateTime timestamp) {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';

    return Text(
      time,
      style: TextStyle(
        fontFamily: 'Consolas',
        fontSize: 11,
        color: Colors.grey[500],
        fontWeight: FontWeight.w500,
      ),
    );
  }

  static Widget _buildLevelBadge(LogLevel level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Color(level.color).withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Color(level.color).withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: Text(
        level.prefix,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Color(level.color),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  static Widget _buildSource(String source) {
    return Text(
      '[$source]',
      style: TextStyle(
        fontFamily: 'Consolas',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF0D6EFD).withOpacity(0.9),
      ),
    );
  }

  static Widget _buildMessage(String message, LogLevel level) {
    // Use appropriate text color based on level
    final textColor = _getTextColor(level);

    return SelectableText(
      message,
      style: TextStyle(
        fontFamily: 'Consolas',
        fontSize: 13,
        color: textColor,
        height: 1.4,
      ),
    );
  }

  static Color _getTextColor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
      case LogLevel.critical:
        return Color(level.color);
      case LogLevel.warning:
        return Color(level.color).withOpacity(0.95);
      default:
        return Colors.grey[200]!;
    }
  }
}
