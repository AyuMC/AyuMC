import 'dart:async';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_package/ayu_package.dart';

final class RegisteredCommand {
  const RegisteredCommand({required this.pluginId, required this.spec});

  final String pluginId;
  final CommandSpec spec;
}

sealed class RegistryChange {
  const RegistryChange(this.pluginId);

  final String pluginId;
}

final class CommandRegistered extends RegistryChange {
  const CommandRegistered(super.pluginId, this.command);

  final RegisteredCommand command;
}

final class CommandUnregistered extends RegistryChange {
  const CommandUnregistered(super.pluginId, this.name);

  final String name;
}

/// Everything plugins register with the host, indexed by owner so a plugin's
/// registrations can be removed in one step the moment it stops.
final class HostRegistry {
  final Map<String, RegisteredCommand> _commandsByName = {};
  final Map<String, Set<String>> _commandNamesByPlugin = {};
  final Map<String, Set<String>> _subscribersByType = {};
  final Map<String, Set<String>> _typesByPlugin = {};
  final StreamController<RegistryChange> _changes = StreamController.broadcast();

  Stream<RegistryChange> get changes => _changes.stream;

  Iterable<RegisteredCommand> get commands => _commandsByName.values.toSet();

  /// Resolves a command by name or alias.
  RegisteredCommand? resolveCommand(String nameOrAlias) => _commandsByName[nameOrAlias.toLowerCase()];

  List<RegisteredCommand> commandsOf(String pluginId) =>
      [for (final name in _commandNamesByPlugin[pluginId] ?? const <String>{}) _commandsByName[name]!];

  Iterable<String> subscribers(String eventType) => _subscribersByType[eventType] ?? const <String>{};

  Set<String> subscriptionsOf(String pluginId) => Set.unmodifiable(_typesByPlugin[pluginId] ?? const <String>{});

  void registerCommand(String pluginId, CommandSpec spec) {
    final keys = <String>[spec.name, ...spec.aliases].map((n) => n.toLowerCase()).toList();
    for (final key in keys) {
      if (!PackageSpec.commandNamePattern.hasMatch(key)) {
        throw IpcException.code(IpcErrorCode.invalidParams,
            'command name "$key" is invalid (lowercase letters, digits, "_" and "-", up to 32 characters)');
      }
    }
    if (keys.toSet().length != keys.length) {
      throw IpcException.code(IpcErrorCode.invalidParams, 'command "${spec.name}" repeats a name or alias');
    }
    for (final key in keys) {
      final existing = _commandsByName[key];
      if (existing != null) {
        throw IpcException.code(IpcErrorCode.conflict,
            'command "$key" is already registered by plugin "${existing.pluginId}"');
      }
    }
    final registered = RegisteredCommand(pluginId: pluginId, spec: spec);
    for (final key in keys) {
      _commandsByName[key] = registered;
    }
    _commandNamesByPlugin.putIfAbsent(pluginId, () => {}).add(spec.name.toLowerCase());
    _changes.add(CommandRegistered(pluginId, registered));
  }

  bool unregisterCommand(String pluginId, String name) {
    final key = name.toLowerCase();
    final existing = _commandsByName[key];
    if (existing == null || existing.pluginId != pluginId || existing.spec.name.toLowerCase() != key) {
      return false;
    }
    _removeCommand(existing);
    return true;
  }

  void subscribe(String pluginId, String eventType) {
    if (!PackageSpec.eventTypePattern.hasMatch(eventType)) {
      throw IpcException.code(IpcErrorCode.invalidParams,
          'event type "$eventType" is invalid (dot-separated lowercase identifiers)');
    }
    _subscribersByType.putIfAbsent(eventType, () => {}).add(pluginId);
    _typesByPlugin.putIfAbsent(pluginId, () => {}).add(eventType);
  }

  bool unsubscribe(String pluginId, String eventType) {
    final removed = _typesByPlugin[pluginId]?.remove(eventType) ?? false;
    if (!removed) return false;
    final subscribers = _subscribersByType[eventType]!..remove(pluginId);
    if (subscribers.isEmpty) _subscribersByType.remove(eventType);
    if (_typesByPlugin[pluginId]!.isEmpty) _typesByPlugin.remove(pluginId);
    return true;
  }

  /// Removes every registration owned by [pluginId].
  void removeAll(String pluginId) {
    for (final command in commandsOf(pluginId)) {
      _removeCommand(command);
    }
    _commandNamesByPlugin.remove(pluginId);
    for (final type in List.of(_typesByPlugin[pluginId] ?? const <String>{})) {
      unsubscribe(pluginId, type);
    }
  }

  Future<void> dispose() => _changes.close();

  void _removeCommand(RegisteredCommand command) {
    for (final key in [command.spec.name, ...command.spec.aliases]) {
      final lower = key.toLowerCase();
      if (identical(_commandsByName[lower], command)) _commandsByName.remove(lower);
    }
    final names = _commandNamesByPlugin[command.pluginId];
    names?.remove(command.spec.name.toLowerCase());
    if (names != null && names.isEmpty) _commandNamesByPlugin.remove(command.pluginId);
    _changes.add(CommandUnregistered(command.pluginId, command.spec.name));
  }
}
