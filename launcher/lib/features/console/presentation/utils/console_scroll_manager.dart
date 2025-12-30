import 'package:flutter/material.dart';

/// Manages scroll behavior for the console log list.
///
/// Handles auto-scrolling logic separately from UI presentation.
class ConsoleScrollManager {
  final ScrollController scrollController = ScrollController();
  bool autoScroll = true;
  int _lastLogCount = 0;

  /// Updates auto-scroll setting.
  void setAutoScroll(bool? value) {
    autoScroll = value ?? true;
  }

  /// Handles new logs being added.
  ///
  /// Triggers auto-scroll if enabled and new logs were added.
  void handleNewLogs(int currentLogCount) {
    if (autoScroll && currentLogCount > _lastLogCount) {
      _scrollToBottom();
    }
    _lastLogCount = currentLogCount;
  }

  void _scrollToBottom() {
    if (!scrollController.hasClients) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Disposes resources.
  void dispose() {
    scrollController.dispose();
  }
}
