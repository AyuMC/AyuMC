import 'package:flutter/material.dart';

import '../../../domain/entities/server_log.dart';

/// Builder for rendering individual log items.
class LogItemBuilder {
  LogItemBuilder._();

  /// Builds a single log item widget.
  static Widget build(ServerLog log) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTimestamp(log.timestamp),
          const SizedBox(width: 8),
          _buildLevelBadge(log.level),
          const SizedBox(width: 8),
          _buildSource(log.source),
          const SizedBox(width: 8),
          Expanded(child: _buildMessage(log.message, log.level)),
        ],
      ),
    );
  }

  static Widget _buildTimestamp(DateTime timestamp) {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';

    return Text(
      time,
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 12,
        color: Color(0xFF6C757D),
      ),
    );
  }

  static Widget _buildLevelBadge(LogLevel level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Color(level.color).withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Color(level.color), width: 1),
      ),
      child: Text(
        level.prefix,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Color(level.color),
        ),
      ),
    );
  }

  static Widget _buildSource(String source) {
    return Text(
      '[$source]',
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0D6EFD),
      ),
    );
  }

  static Widget _buildMessage(String message, LogLevel level) {
    return Text(
      message,
      style: TextStyle(
        fontFamily: 'Consolas',
        fontSize: 12,
        color: Color(level.color),
      ),
    );
  }
}
