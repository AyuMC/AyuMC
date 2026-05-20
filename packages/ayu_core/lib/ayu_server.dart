import 'package:ayu_commands/command.dart';
import 'package:ayu_commands/command_manager.dart';
import 'package:ayu_logging/logger.dart';
import 'ayu_lifecycle.dart';
import 'ayu_states.dart';

class AyuServer {
  final Logger logger = Logger('AyuMC');
  final ServerLifecycle lifecycle = ServerLifecycle();
  final CommandManager commands = CommandManager();

  Future<void> start() async {
    lifecycle.setState(ServerState.starting);
    logger.info('Server starting...');
    commands.register(
      Command(
        name: 'ping',
        description: 'Test command',
        execute: (args) {
          logger.info('pong!');
        },
      ),
    );

    commands.register(
      Command(
        name: 'say',
        description: 'Broadcast message',
        execute: (args) {
          logger.info(args.join(' '));
        },
      ),
    );
    await Future.delayed(Duration(seconds: 1));
    logger.info('Server Started.');
    lifecycle.setState(ServerState.running);
  }

  Future<void> stop() async {
    lifecycle.setState(ServerState.stopping);
    logger.info('Server stopping...');
    await Future.delayed(Duration(seconds: 1));
    logger.warn('Server stopped.');
    lifecycle.setState(ServerState.stopped);
  }
}
