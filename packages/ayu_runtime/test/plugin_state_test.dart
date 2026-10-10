import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('every state has an entry in the transition table', () {
    for (final state in PluginState.values) {
      expect(PluginStateMachine.allowed.containsKey(state), isTrue, reason: state.name);
    }
  });

  test('the nominal path is allowed', () {
    const path = [
      PluginState.discovered,
      PluginState.validating,
      PluginState.staged,
      PluginState.starting,
      PluginState.active,
      PluginState.stopping,
      PluginState.disabled,
      PluginState.starting,
      PluginState.active,
      PluginState.crashed,
      PluginState.starting,
      PluginState.failed,
      PluginState.disabled,
    ];
    for (var i = 1; i < path.length; i++) {
      expect(PluginStateMachine.canTransition(path[i - 1], path[i]), isTrue, reason: '${path[i - 1].name} -> ${path[i].name}');
    }
  });

  test('skipping states is rejected', () {
    expect(PluginStateMachine.canTransition(PluginState.disabled, PluginState.active), isFalse);
    expect(PluginStateMachine.canTransition(PluginState.active, PluginState.disabled), isFalse);
    expect(PluginStateMachine.canTransition(PluginState.staged, PluginState.active), isFalse);
    expect(() => PluginStateMachine.check('p', PluginState.active, PluginState.active), throwsA(isA<InvalidStateTransition>()));
  });

  test('hasWorker covers exactly the states with a live process', () {
    expect(PluginState.values.where((s) => s.hasWorker), [PluginState.starting, PluginState.active, PluginState.stopping]);
  });
}
