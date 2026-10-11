import 'dart:async';

import 'package:ayu_ipc/ayu_ipc.dart';

/// A public event contract. [id] is what the host routes. [decode] builds the typed payload.
final class EventContract<T> {
  const EventContract({
    required this.id,
    required this.version,
    required this.decode,
  });

  final String id;
  final String version;
  final T Function(Map<String, Object?> data) decode;
}

/// A handler the runner can subscribe without knowing [T].
abstract interface class BoundHandler {
  String get contractId;
  void dispatch(Map<String, Object?> data);
}

/// One typed handler. Created with [on].
final class EventBinding<T> implements BoundHandler {
  EventBinding(this.contract, this.handle);

  final EventContract<T> contract;
  final void Function(T event) handle;

  @override
  String get contractId => contract.id;

  @override
  void dispatch(Map<String, Object?> data) => handle(contract.decode(data));
}

/// Binds [handle] to [contract]. The handler's argument type must match the contract.
EventBinding<T> on<T>(
  EventContract<T> contract,
  void Function(T event) handle,
) => EventBinding(contract, handle);

/// A group of event handlers. Declare instances once; do not allocate them in the getter.
abstract class Listener {
  List<BoundHandler> get handlers => const [];
}

/// A console command. This is not a Minecraft chat command.
abstract class PluginCommand {
  String get name;
  String get description => '';
  String get usage => '';
  List<String> get aliases => const [];
  FutureOr<CommandResult> execute(CommandInvocation call);
}
