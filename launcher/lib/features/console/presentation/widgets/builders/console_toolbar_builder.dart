import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../domain/entities/server_log.dart';

/// Builder for the console toolbar with filters and actions.
class ConsoleToolbarBuilder {
  ConsoleToolbarBuilder._();

  /// Builds the console toolbar with glassmorphism effect.
  static Widget build({
    required VoidCallback onClear,
    required Function(LogLevel?) onFilterChanged,
    required Function(String) onSearch,
    LogLevel? currentFilter,
  }) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[900]?.withOpacity(0.8),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              _buildClearButton(onClear),
              const SizedBox(width: 12),
              _buildFilterDropdown(onFilterChanged, currentFilter),
              const SizedBox(width: 12),
              Expanded(child: _buildSearchField(onSearch)),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildClearButton(VoidCallback onClear) {
    return ElevatedButton.icon(
      onPressed: onClear,
      icon: const Icon(Icons.clear_all, size: 16),
      label: const Text('Clear'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.red[700],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
      ),
    );
  }

  static Widget _buildFilterDropdown(
    Function(LogLevel?) onFilterChanged,
    LogLevel? currentFilter,
  ) {
    return DropdownButton<LogLevel?>(
      value: currentFilter,
      hint: const Text('All Levels'),
      dropdownColor: Colors.grey[850],
      items: [
        const DropdownMenuItem<LogLevel?>(
          value: null,
          child: Text('All Levels'),
        ),
        ...LogLevel.values.map(
          (level) => DropdownMenuItem<LogLevel?>(
            value: level,
            child: Text(level.prefix),
          ),
        ),
      ],
      onChanged: onFilterChanged,
    );
  }

  static Widget _buildSearchField(Function(String) onSearch) {
    return TextField(
      onChanged: onSearch,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Search logs...',
        prefixIcon: const Icon(Icons.search, size: 20),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        filled: true,
        fillColor: Colors.grey[850],
      ),
    );
  }
}
