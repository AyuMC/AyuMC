import 'dart:convert';
import 'dart:typed_data';

/// Fixed-size ring buffer keeping the most recent stderr bytes of a worker.
final class StderrTail {
  StderrTail(this.capacity) : _buffer = Uint8List(capacity);

  final int capacity;
  final Uint8List _buffer;
  int _write = 0;
  int _length = 0;

  void add(List<int> bytes) {
    if (bytes.length >= capacity) {
      _buffer.setRange(0, capacity, bytes, bytes.length - capacity);
      _write = 0;
      _length = capacity;
      return;
    }
    final first = capacity - _write;
    if (bytes.length <= first) {
      _buffer.setRange(_write, _write + bytes.length, bytes);
    } else {
      _buffer.setRange(_write, capacity, bytes, 0);
      _buffer.setRange(0, bytes.length - first, bytes, first);
    }
    _write = (_write + bytes.length) % capacity;
    _length = _length + bytes.length > capacity ? capacity : _length + bytes.length;
  }

  bool get isEmpty => _length == 0;

  @override
  String toString() {
    if (_length == 0) return '';
    final out = Uint8List(_length);
    if (_length < capacity) {
      out.setRange(0, _length, _buffer, 0);
    } else {
      out.setRange(0, capacity - _write, _buffer, _write);
      out.setRange(capacity - _write, capacity, _buffer, 0);
    }
    return const Utf8Decoder(allowMalformed: true).convert(out).trim();
  }
}
