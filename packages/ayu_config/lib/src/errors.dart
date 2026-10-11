/// A problem found while reading or checking an `.ayuconf` file.
final class ConfigProblem {
  const ConfigProblem(this.message, {this.key, this.line, this.column});

  final String message;
  final String? key;
  final int? line;
  final int? column;

  @override
  String toString() {
    final where = [
      if (key != null) key,
      if (line != null) 'line $line${column == null ? '' : ':$column'}',
    ].join(' ');
    return where.isEmpty ? message : '$where: $message';
  }
}

/// Thrown when a placeholder is rendered without the context it requires.
final class PlaceholderException implements Exception {
  const PlaceholderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of trying to make a file the active configuration.
final class ConfigLoadResult {
  const ConfigLoadResult({
    required this.applied,
    required this.revision,
    this.problems = const [],
    this.warnings = const [],
    this.state = 'applied',
  });

  final bool applied;
  final int revision;
  final List<ConfigProblem> problems;
  final List<String> warnings;

  /// `applied`, `rejected`, `migration failed`, or `watcher failed`.
  final String state;

  String get summary {
    if (applied && warnings.isEmpty) return 'applied revision $revision';
    if (applied) return 'applied revision $revision (${warnings.join('; ')})';
    return problems.map((problem) => problem.toString()).join('; ');
  }
}
