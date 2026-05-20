typedef CommandExecutor = void Function(List<String> args);

class Command {
  final String name;

  final String description;

  final CommandExecutor execute;

  Command({
    required this.name,
    required this.description,
    required this.execute,
  });
}
