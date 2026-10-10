import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 helpers. Integrity only: a matching digest proves the bytes are
/// the ones the manifest author hashed, not that the author is trustworthy.
abstract final class Integrity {
  static final RegExp sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static Future<String> sha256HexOfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).single;
    return digest.toString();
  }

  /// Builds a sink that hashes everything written to it. Call `close()` and
  /// read [DigestSink.value].
  static DigestSink sink() => DigestSink._();
}

final class DigestSink implements Sink<List<int>> {
  DigestSink._() {
    _inner = sha256.startChunkedConversion(_output);
  }

  final _DigestOutput _output = _DigestOutput();
  late final ByteConversionSink _inner;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void close() => _inner.close();

  String get value {
    final digest = _output.digest;
    if (digest == null) throw StateError('digest sink not closed');
    return digest.toString();
  }
}

final class _DigestOutput implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
