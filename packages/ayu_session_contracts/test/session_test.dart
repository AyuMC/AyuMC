import 'package:ayu_session_contracts/session.dart';
import 'package:test/test.dart';

void main() {
  test('session.joined decodes the player fields from the wire payload', () {
    final event = SessionEvents.joined.decode({
      'name': 'Steve',
      'uuid': 'abc',
      'entityId': 7,
    });
    expect(SessionEvents.joined.id, 'session.joined');
    expect(SessionEvents.joined.version, '1.0.0');
    expect(event.player.name, 'Steve');
    expect(event.player.uuid, 'abc');
    expect(event.player.entityId, 7);
  });

  test('a missing name does not throw; it stays empty', () {
    final event = SessionEvents.left.decode(const {});
    expect(event.player.name, isEmpty);
    expect(event.player.entityId, 0);
  });
}
