import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'buffer.dart';

/// Java's offline-mode UUID: `UUID.nameUUIDFromBytes("OfflinePlayer:" + name)`.
/// Online authentication is not implemented; this is only valid in offline mode.
/// Sixteen bytes of the offline UUID, in the order protocol 47 writes a UUID.
Uint8List offlinePlayerUuidBytes(String name) {
  final digest = Uint8List.fromList(
    md5.convert(utf8Strict.encode('OfflinePlayer:$name')).bytes,
  );
  digest[6] = (digest[6] & 0x0f) | 0x30;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  return digest;
}

String offlinePlayerUuid(String name) {
  final hex = offlinePlayerUuidBytes(
    name,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
