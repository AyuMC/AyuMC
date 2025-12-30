import 'package:flutter/material.dart';

/// Builds the console status bar at the bottom.
class ConsoleStatusBarBuilder {
  ConsoleStatusBarBuilder._();

  /// Builds the status bar widget.
  static Widget build({
    required int logCount,
    required bool autoScroll,
    required Function(bool?) onAutoScrollChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900]?.withOpacity(0.95),
        border: Border(top: BorderSide(color: Colors.grey[800]!, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildLogCounter(logCount),
          _buildAutoScrollToggle(autoScroll, onAutoScrollChanged),
        ],
      ),
    );
  }

  static Widget _buildLogCounter(int count) {
    return Row(
      children: [
        Icon(Icons.description_outlined, size: 16, color: Colors.grey[400]),
        const SizedBox(width: 8),
        Text(
          '$count ${count == 1 ? 'log' : 'logs'}',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[400],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  static Widget _buildAutoScrollToggle(
    bool autoScroll,
    Function(bool?) onChanged,
  ) {
    return Row(
      children: [
        Checkbox(
          value: autoScroll,
          onChanged: onChanged,
          activeColor: const Color(0xFF0D6EFD),
        ),
        Text(
          'Auto-scroll',
          style: TextStyle(fontSize: 13, color: Colors.grey[400]),
        ),
      ],
    );
  }
}
