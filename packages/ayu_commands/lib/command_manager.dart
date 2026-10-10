import 'package:ayu_logging/logger.dart';

import 'command.dart';

/// Registry and dispatcher of console commands. Names are case-insensitive.
class CommandManager {
  final Logger logger = Logger('Commands');

  final Map<String, Command> _commands = {};

  Iterable<Command> get commands => _commands.values;

  bool has(String name) => _commands.containsKey(name.toLowerCase());

  void register(Command command) {
    final key = command.name.toLowerCase();
    if (_commands.containsKey(key)) {
      throw ArgumentError.value(command.name, 'command', 'is already registered');
    }
    _commands[key] = command;
    logger.info('Registered command: ${command.name}');
  }

  bool unregister(String name) {
    final removed = _commands.remove(name.toLowerCase());
    if (removed != null) logger.info('Unregistered command: ${removed.name}');
    return removed != null;
  }

  /// Parses `input` as `<name> [args...]` and runs the command. Errors
  /// thrown by the executor are logged, never propagated to the console.
  Future<void> execute(String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return;

    final name = parts.first;
    final args = parts.skip(1).toList();
    final command = _commands[name.toLowerCase()];

    if (command == null) {
      logger.error('Unknown command: $name');
      return;
    }
    try {
      await command.execute(args);
    } catch (error) {
      logger.error('Command "$name" failed: $error');
    }
  }
}
