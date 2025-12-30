import 'package:flutter/material.dart';

import '../../../domain/entities/server_log.dart';
import 'log_item_builder.dart';

/// Builds the main console content area with logs list.
class ConsoleContentBuilder {
  ConsoleContentBuilder._();

  /// Builds the logs list view.
  static Widget buildLogsList({
    required List<ServerLog> logs,
    required ScrollController scrollController,
  }) {
    if (logs.isEmpty) {
      return _buildEmptyState();
    }

    return Container(
      color: Colors.black,
      child: ListView.builder(
        controller: scrollController,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          return LogItemBuilder.build(logs[index]);
        },
      ),
    );
  }

  static Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 64, color: Colors.grey[700]),
          const SizedBox(height: 16),
          Text(
            'No logs yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Server logs will appear here when the server is running',
            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }
}
