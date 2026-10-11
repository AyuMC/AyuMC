import 'dart:async';

import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('only the position primitive is coalesced', () {
    final position = primitiveDeliverySpec(
      'core.player.position',
      queueLimit: 8192,
    );
    expect(position.overflow, OverflowPolicy.coalesce);
    expect(position.coalesceKey, 'entityId');

    final joined = primitiveDeliverySpec(
      'core.session.play_joined',
      queueLimit: 8192,
    );
    final left = primitiveDeliverySpec('core.session.closed', queueLimit: 8192);
    expect(joined.overflow, OverflowPolicy.gap);
    expect(joined.coalesceKey, isNull);
    expect(left.overflow, OverflowPolicy.gap);
  });

  test(
    'a pending position replaces the previous one, and a sent position does not',
    () async {
      final sent = <Object?>[];
      final box = _box(sent);
      final spec = primitiveDeliverySpec(
        'core.player.position',
        queueLimit: 8192,
      );
      box.enqueue('core.player.position', spec, _position(1));
      box.enqueue('core.player.position', spec, _position(2));
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(1));
      expect(sent.single, _position(2));

      box.enqueue('core.player.position', spec, _position(3));
      await Future<void>.delayed(Duration.zero);
      expect(sent, [_position(2), _position(3)]);
      box.close();
    },
  );

  test(
    'distinct entities stay distinct, and join events are not merged',
    () async {
      final sent = <Object?>[];
      final box = _box(sent);
      final position = primitiveDeliverySpec(
        'core.player.position',
        queueLimit: 8192,
      );
      box.enqueue('core.player.position', position, _position(1, entityId: 4));
      box.enqueue('core.player.position', position, _position(2, entityId: 9));
      final joined = primitiveDeliverySpec(
        'core.session.play_joined',
        queueLimit: 8192,
      );
      box.enqueue('core.session.play_joined', joined, _join('Steve'));
      box.enqueue('core.session.play_joined', joined, _join('Alex'));
      await Future<void>.delayed(Duration.zero);

      final batches = sent
          .whereType<Map>()
          .where((frame) => frame['items'] is List)
          .toList();
      expect(batches, hasLength(2));
      final positions = batches
          .map((frame) => (frame['items'] as List).cast<Map>())
          .toList();
      expect(
        positions.any(
          (items) =>
              items.length == 2 && items.first['id'] == 'core.player.position',
        ),
        isTrue,
      );
      expect(
        positions.any(
          (items) =>
              items.length == 2 &&
              items.first['id'] == 'core.session.play_joined',
        ),
        isTrue,
      );
      box.close();
    },
  );
}

WorkerOutbox _box(List<Object?> sent) {
  return WorkerOutbox(
    send: (method, params) {
      sent.add(params);
      return true;
    },
    singleMethod: 'primitive',
    batchMethod: 'primitive.batch',
    maxBatchItems: 32,
    onGap: (_, _) {},
  );
}

Map<String, Object?> _position(int x, {int entityId = 7}) => {
  'id': 'core.player.position',
  'data': {'entityId': entityId, 'x': x},
  'ts': x,
};

Map<String, Object?> _join(String name) => {
  'id': 'core.session.play_joined',
  'data': {'name': name},
  'ts': name.length,
};
