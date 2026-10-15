import 'dart:io';
import 'dart:typed_data';

import 'buffer.dart';

/// Protocol-47 transport compression.
///
/// Minecraft Java Edition 1.8.9 negotiates compression during login with the
/// Login Set Compression packet (login state, id `0x03`, body is one VarInt
/// threshold). Every packet after that point uses the compressed framing:
///
/// ```text
/// VarInt  length      bytes of everything that follows
/// VarInt  dataLength  uncompressed size, or 0 when the payload is uncompressed
/// bytes   payload     zlib data when dataLength != 0, the packet when 0
/// ```
///
/// A packet smaller than the threshold is still sent with this framing and an
/// explicit `dataLength` of zero. That is what makes the framing unambiguous.
///
/// The protocol has no in-play renegotiation. A new threshold applies to
/// connections that log in after the change; it cannot be pushed to live
/// sockets.
final class FrameCodec {
  /// Value that disables compression. The protocol expresses "disabled" by
  /// never sending Set Compression, not by sending a negative threshold.
  static const disabled = -1;

  int _threshold = disabled;
  bool activated = false;

  bool get enabled => activated && _threshold >= 0;

  /// `-1` disables compression, `0` compresses everything, a positive value is
  /// the smallest payload that is compressed.
  int get threshold => _threshold;

  void activate(int threshold) {
    _threshold = threshold < 0 ? disabled : threshold;
    activated = true;
  }

  /// Frames one packet according to the negotiated state.
  Uint8List frame(Uint8List packet) {
    if (!enabled) return packet;
    return encodeCompressedFrame(packet, _threshold);
  }

  /// Restores the pre-negotiation state. Tests and reconnects use this.
  void reset() {
    _threshold = disabled;
    activated = false;
  }
}

/// Login Set Compression packet body, queued before the connection switches
/// to compressed framing.
Uint8List setCompressionPacket(int threshold) =>
    encodePacket(0x03, encodeVarInt(threshold < 0 ? 0 : threshold));

/// Frames [packet] with the compressed framing at [threshold].
///
/// The output for one input and threshold is deterministic, so a caller may
/// hand the same buffer to several sockets.
Uint8List encodeCompressedFrame(Uint8List packet, int threshold) {
  final uncompressedLength = packet.length;
  if (threshold <= 0 || uncompressedLength >= threshold) {
    final compressed = zlib.encode(packet);
    final dataLength = encodeVarInt(uncompressedLength);
    return Uint8List.fromList([
      ...encodeVarInt(dataLength.length + compressed.length),
      ...dataLength,
      ...compressed,
    ]);
  }
  final zero = encodeVarInt(0);
  return Uint8List.fromList([
    ...encodeVarInt(zero.length + uncompressedLength),
    ...zero,
    ...packet,
  ]);
}

/// Decodes one compressed-framed payload into the original packet bytes.
///
/// Used by tests and by the benchmark clients. The server path decodes through
/// [PacketBuffer.readCompressedFrame] so partial reads keep buffering.
Uint8List decodeCompressedFrame(Uint8List frame, {int maxUncompressed = 1 << 21}) {
  final body = PacketBuffer()..add(frame);
  final length = body.readVarInt();
  final dataLength = body.readVarInt();
  if (length < 0 || dataLength < 0) {
    throw const PacketFormatException('negative compressed frame length');
  }
  if (dataLength > maxUncompressed) {
    throw PacketFormatException(
      'decompressed size $dataLength exceeds $maxUncompressed',
    );
  }
  final payload = body.readBytes(body.length);
  if (dataLength == 0) return payload;
  final decoded = _inflate(payload, dataLength);
  return decoded;
}

Uint8List _inflate(Uint8List payload, int expected) {
  final List<int> decoded;
  try {
    decoded = zlib.decode(payload);
  } on FormatException catch (error) {
    throw PacketFormatException('zlib payload is invalid: ${error.message}');
  }
  if (decoded.length != expected) {
    throw PacketFormatException(
      'decompressed size ${decoded.length} does not match declared $expected',
    );
  }
  return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
}

/// Size of [value] as a VarInt. The frame headers are built from this without
/// allocating an intermediate list.
int varIntSize(int value) {
  var rest = value < 0 ? value & 0xFFFFFFFF : value;
  var size = 1;
  while (rest >= 0x80) {
    size++;
    rest >>= 7;
  }
  return size;
}
