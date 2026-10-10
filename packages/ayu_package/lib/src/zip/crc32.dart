import 'dart:typed_data';

/// Table-driven CRC-32 (IEEE 802.3, polynomial 0xEDB88320) as used by ZIP.
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

  /// Continues a running checksum. Start with `0`.
  static int update(int crc, List<int> bytes, [int start = 0, int? end]) {
    var c = crc ^ 0xFFFFFFFF;
    final stop = end ?? bytes.length;
    for (var i = start; i < stop; i++) {
      c = _table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    }
    return c ^ 0xFFFFFFFF;
  }

  static int compute(List<int> bytes) => update(0, bytes);
}
