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
  bool _wait = false;

  List<KeyEvent> add(List<int> bytes) {
    _pending.addAll(bytes);
    final events = <KeyEvent>[];
    while (_pending.isNotEmpty) {
      _wait = false;
      final event = _take();
      if (_wait) break;
      if (event != null) events.add(event);
    }
    return events;
  }

  KeyEvent? _take() {
    final lead = _pending.first;
    if (lead == 0x1b) return _escape();
    if (lead == 0x00 || lead == 0xe0) return _windowsFunction();
    _pending.removeAt(0);
    if (lead == 0x0d || lead == 0x0a) {
      return const KeyEvent.nav(ManagerKey.enter);
    }
    if (lead == 0x7f || lead == 0x08) {
      return const KeyEvent.nav(ManagerKey.backspace);
    }
    if (lead == 0x03) return const KeyEvent.nav(ManagerKey.quit);
    if (lead >= 0x20 && lead < 0x7f) {
      return KeyEvent.text(String.fromCharCode(lead));
    }
    return null;
  }

  KeyEvent? _escape() {
    if (_pending.length < 2) {
      _wait = true;
      return null;
    }
    // ESC O x — application cursor mode and some function keys.
    if (_pending[1] == 0x4f) {
      if (_pending.length < 3) {
        _wait = true;
        return null;
      }
      final key = _ss3(_pending[2]);
      _pending.removeRange(0, 3);
      return key == null ? null : KeyEvent.nav(key);
    }
    // ESC [ ... final. Arrow keys end on A/B. Function keys end on ~.
    // Waiting only for ~ left ESC [ A in the buffer and ignored every later key.
    if (_pending[1] == 0x5b) {
      var index = 2;
      while (index < _pending.length && index < 16) {
        final byte = _pending[index];
        if (byte >= 0x40 && byte <= 0x7e) {
          final params = String.fromCharCodes(_pending.sublist(2, index));
          final key = _csi(params, byte);
          _pending.removeRange(0, index + 1);
          return key == null ? null : KeyEvent.nav(key);
        }
        if (byte < 0x20 || byte > 0x3f) break;
        index++;
      }
      if (_pending.length >= 16) {
        _pending.removeAt(0);
        return const KeyEvent.nav(ManagerKey.escape);
      }
      _wait = true;
      return null;
    }
    _pending.removeAt(0);
    return const KeyEvent.nav(ManagerKey.escape);
  }

  ManagerKey? _ss3(int byte) => switch (byte) {
    0x41 => ManagerKey.up,
    0x42 => ManagerKey.down,
    0x50 => ManagerKey.f1,
    0x51 => ManagerKey.f2,
    0x52 => ManagerKey.f3,
    0x53 => ManagerKey.f4,
    _ => null,
  };

  /// [finalByte] is the CSI terminator. [params] is the text between `[` and it.
  ManagerKey? _csi(String params, int finalByte) {
    if (finalByte == 0x41) return ManagerKey.up;
    if (finalByte == 0x42) return ManagerKey.down;
    if (finalByte != 0x7e) return null;
    final code = params.split(';').first;
    return switch (code) {
      '11' => ManagerKey.f1,
      '12' => ManagerKey.f2,
      '13' => ManagerKey.f3,
      '14' => ManagerKey.f4,
      '15' => ManagerKey.f5,
      '17' => ManagerKey.f6,
      _ => null,
    };
  }

  KeyEvent? _windowsFunction() {
    if (_pending.length < 2) {
      _wait = true;
      return null;
    }
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
