import 'dart:io';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_manager/ayu_manager.dart';
import 'package:test/test.dart';

void main() {
  test('function keys from Unix and Windows sequences select sections', () {
    final decoder = KeyDecoder();
    expect(decoder.add([0x1b, 0x4f, 0x50]).single.key, ManagerKey.f1);
    expect(
      decoder.add([0x1b, 0x5b, 0x31, 0x37, 0x7e]).single.key,
      ManagerKey.f6,
    );
    expect(decoder.add([0x00, 0x3c]).single.key, ManagerKey.f2);
    expect(decoder.add([0x1b, 0x5b, 0x41]).single.key, ManagerKey.up);
    expect(decoder.add([0x1b, 0x5b, 0x42]).single.key, ManagerKey.down);
    expect(decoder.add([0x1b, 0x4f, 0x41]).single.key, ManagerKey.up);
    expect(decoder.add([0xe0, 0x48]).single.key, ManagerKey.up);
    final split = KeyDecoder();
    expect(split.add([0x1b, 0x5b]), isEmpty);
    expect(split.add([0x31, 0x35, 0x7e]).single.key, ManagerKey.f5);
    final arrows = KeyDecoder();
    for (var i = 0; i < 20; i++) {
      expect(arrows.add([0x1b, 0x5b, 0x42]).single.key, ManagerKey.down);
    }
    final followed = arrows.add([0x1b, 0x5b, 0x41, 0x72]);
    expect(followed.first.key, ManagerKey.up);
    expect(followed.last.text, 'r');
  });

  test('F1 through F6 change the visible section', () {
    final session = ManagerSession(
      control: ServerControl(root: Directory.systemTemp),
    );
    session.apply(const KeyEvent.nav(ManagerKey.f1));
    expect(session.section, ManagerSection.logs);
    session.apply(const KeyEvent.nav(ManagerKey.f3));
    expect(session.section, ManagerSection.events);
    expect(session.render(color: false), contains('No event packs installed'));
    session.apply(const KeyEvent.text('6'));
    expect(session.section, ManagerSection.controls);
    expect(session.render(color: false), contains('restart'));
  });

  test('uptime text follows the moment the server started', () {
    final control = ServerControl(root: Directory.systemTemp);
    control.state = ServerRunState.running;
    control.startedAt = DateTime.now().subtract(const Duration(seconds: 5));
    final session = ManagerSession(control: control);
    expect(session.render(color: false), contains('up 0:00:05'));
  });

  test('log history drops the oldest line and remembers that it did', () {
    final buffer = LogBuffer(capacity: 2);
    buffer.add(
      LogRecord(
        time: DateTime.utc(2026),
        loggerName: 'a',
        level: LogLevel.info,
        message: 'one',
      ),
    );
    buffer.add(
      LogRecord(
        time: DateTime.utc(2026),
        loggerName: 'a',
        level: LogLevel.info,
        message: 'two',
      ),
    );
    buffer.add(
      LogRecord(
        time: DateTime.utc(2026),
        loggerName: 'a',
        level: LogLevel.error,
        message: 'three',
      ),
    );
    expect(buffer.lines.map((line) => line.message), ['two', 'three']);
    expect(buffer.dropped, 1);
    expect(buffer.filtered(minimum: LogLevel.error).single.message, 'three');
  });

  test('a second start is refused without launching another server', () async {
    final control = ServerControl(root: Directory.systemTemp);
    control.state = ServerRunState.running;
    expect(await control.start(), contains('already'));
    expect(control.state, ServerRunState.running);
  });

  test('stop on an idle controller does not hang', () async {
    final control = ServerControl(root: Directory.systemTemp);
    expect(await control.stop(), 'server is stopped');
  });
}
