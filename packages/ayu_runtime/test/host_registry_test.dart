import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:test/test.dart';

void main() {
  late HostRegistry registry;

  setUp(() => registry = HostRegistry());
  tearDown(() => registry.dispose());

  test('registers commands with aliases and resolves case-insensitively', () {
    registry.registerCommand('a', CommandSpec(name: 'heal', aliases: ['h']));
    expect(registry.resolveCommand('HEAL')?.pluginId, 'a');
    expect(registry.resolveCommand('h')?.spec.name, 'heal');
    expect(registry.commandsOf('a').single.spec.name, 'heal');
  });

  test('rejects conflicts across plugins and invalid names', () {
    registry.registerCommand('a', CommandSpec(name: 'heal', aliases: ['h']));
    expect(() => registry.registerCommand('b', CommandSpec(name: 'h')),
        throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.conflict)));
    expect(() => registry.registerCommand('b', CommandSpec(name: 'Bad Name')),
        throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.invalidParams)));
    expect(() => registry.registerCommand('b', CommandSpec(name: 'x', aliases: ['x'])),
        throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.invalidParams)));
  });

  test('unregister only works for the owner and by primary name', () {
    registry.registerCommand('a', CommandSpec(name: 'heal', aliases: ['h']));
    expect(registry.unregisterCommand('b', 'heal'), isFalse);
    expect(registry.unregisterCommand('a', 'h'), isFalse);
    expect(registry.unregisterCommand('a', 'heal'), isTrue);
    expect(registry.resolveCommand('h'), isNull);
  });

  test('removeAll drops commands and subscriptions of one plugin only', () async {
    final changes = <RegistryChange>[];
    registry.changes.listen(changes.add);
    registry.registerCommand('a', CommandSpec(name: 'one'));
    registry.registerCommand('b', CommandSpec(name: 'two'));
    registry.subscribe('a', 'player.join');
    registry.subscribe('b', 'player.join');
    registry.subscribe('a', 'server.started');

    registry.removeAll('a');
    expect(registry.resolveCommand('one'), isNull);
    expect(registry.resolveCommand('two')?.pluginId, 'b');
    expect(registry.subscribers('player.join'), ['b']);
    expect(registry.subscribers('server.started'), isEmpty);
    expect(registry.subscriptionsOf('a'), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(changes.whereType<CommandUnregistered>().map((c) => c.name), ['one']);
  });

  test('validates event type names', () {
    expect(() => registry.subscribe('a', 'Player.Join'), throwsA(isA<IpcException>()));
    registry.subscribe('a', 'player.join');
    expect(registry.unsubscribe('a', 'player.join'), isTrue);
    expect(registry.unsubscribe('a', 'player.join'), isFalse);
  });
}
