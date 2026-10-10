/// Keys the manager understands. Byte sequences differ by terminal; [KeyDecoder] accepts the common ones.
enum ManagerKey {
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  up,
  down,
  enter,
  escape,
  backspace,
  pause,
  quit,
}

final class KeyEvent {
  const KeyEvent.nav(this.key) : text = null;
  const KeyEvent.text(this.text) : key = null;

  final ManagerKey? key;
  final String? text;
}

/// Incremental decoder for function keys and typed characters.
final class KeyDecoder {
  final List<int> _pending = [];

  List<KeyEvent> add(List<int> bytes) {
    _pending.addAll(bytes);
    final events = <KeyEvent>[];
    while (_pending.isNotEmpty) {
      final event = _take();
      if (event == null) break;
      events.add(event);
    }
    return events;
  }

  KeyEvent? _take() {
    final lead = _pending.first;
    if (lead == 0x1b) return _escape();
    if (lead == 0x00 || lead == 0xe0) return _windowsFunction();
    _pending.removeAt(0);
    if (lead == 0x0d || lead == 0x0a)
      return const KeyEvent.nav(ManagerKey.enter);
    if (lead == 0x7f || lead == 0x08)
      return const KeyEvent.nav(ManagerKey.backspace);
    if (lead == 0x03) return const KeyEvent.nav(ManagerKey.quit);
    if (lead >= 0x20 && lead < 0x7f)
      return KeyEvent.text(String.fromCharCode(lead));
    return null;
  }

  KeyEvent? _escape() {
    if (_pending.length < 2) return null;
    if (_pending[1] == 0x4f && _pending.length >= 3) {
      final key = switch (_pending[2]) {
        0x50 => ManagerKey.f1,
        0x51 => ManagerKey.f2,
        0x52 => ManagerKey.f3,
        0x53 => ManagerKey.f4,
        _ => null,
      };
      if (key == null) {
        _pending.removeRange(0, 3);
        return null;
      }
      _pending.removeRange(0, 3);
      return KeyEvent.nav(key);
    }
    if (_pending[1] == 0x5b) {
      final end = _pending.indexOf(0x7e);
      if (end < 0) {
        if (_pending.length > 8) _pending.removeAt(0);
        return null;
      }
      final body = String.fromCharCodes(_pending.sublist(2, end));
      final key = switch (body) {
        '11' => ManagerKey.f1,
        '12' => ManagerKey.f2,
        '13' => ManagerKey.f3,
        '14' => ManagerKey.f4,
        '15' => ManagerKey.f5,
        '17' => ManagerKey.f6,
        'A' => ManagerKey.up,
        'B' => ManagerKey.down,
        _ => null,
      };
      _pending.removeRange(0, end + 1);
      return key == null ? null : KeyEvent.nav(key);
    }
    _pending.removeAt(0);
    return const KeyEvent.nav(ManagerKey.escape);
  }

  KeyEvent? _windowsFunction() {
    if (_pending.length < 2) return null;
    final key = switch (_pending[1]) {
      0x3b => ManagerKey.f1,
      0x3c => ManagerKey.f2,
      0x3d => ManagerKey.f3,
      0x3e => ManagerKey.f4,
      0x3f => ManagerKey.f5,
      0x40 => ManagerKey.f6,
      0x48 => ManagerKey.up,
      0x50 => ManagerKey.down,
      _ => null,
    };
    _pending.removeRange(0, 2);
    return key == null ? null : KeyEvent.nav(key);
  }
}

ManagerKey? sectionKey(int number) => switch (number) {
  1 => ManagerKey.f1,
  2 => ManagerKey.f2,
  3 => ManagerKey.f3,
  4 => ManagerKey.f4,
  5 => ManagerKey.f5,
  6 => ManagerKey.f6,
  _ => null,
};
