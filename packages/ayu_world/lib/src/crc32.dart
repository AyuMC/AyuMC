import 'dart:typed_data';

/// IEEE CRC-32 used by region-log records.
abstract final class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[i] = c;
    }
    return table;
  }

  static int compute(List<int> bytes, [int start = 0, int? end]) {
    var c = 0xFFFFFFFF;
    final stop = end ?? bytes.length;
    for (var i = start; i < stop; i++) {
      c = _table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
