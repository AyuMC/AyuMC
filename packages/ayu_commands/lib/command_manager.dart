import 'package:ayu_logging/logger.dart';
import 'command.dart';

class CommandManager {
  final Logger logger = Logger('Commands');

  final Map<String, Command> _commands = {};

  void register(Command command) {
    _commands[command.name] = command;

    logger.info('Registered command: ${command.name}');
  }

  void execute(String input) {
    final parts = input.split(' ');

    if (parts.isEmpty) return;

    final name = parts.first;

    final args = parts.skip(1).toList();

    final command = _commands[name];

    if (command == null) {
      logger.error('Unknown command: $name');
      return;
    }

    command.execute(args);
  }
}
