import 'dart:async';

/// Executes a command. May be asynchronous; the manager awaits it.
typedef CommandExecutor = FutureOr<void> Function(List<String> args);

class Command {
  const Command({
    required this.name,
    required this.description,
    required this.execute,
  });

  final String name;
  final String description;
  final CommandExecutor execute;
}
