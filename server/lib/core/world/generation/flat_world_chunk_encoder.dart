import 'dart:typed_data';
import '../../protocol/packets/play/chunk_packet.dart';
import '../chunk/chunk.dart';
import '../map_dimension.dart';

/// Fast encoder for flat-world chunks.
///
/// The goal is to keep chunk encoding as close to O(1) as possible by using
/// templates and cached constant payloads.
class FlatWorldChunkEncoder {
  FlatWorldChunkEncoder._();

  /// Encodes chunk data payload (without packet ID and length) for a flat chunk.
  ///
  /// Returns only the payload bytes (packet ID and length are added by Packet wrapper).
  /// This allows protocol-aware packet ID assignment in ChunkSender.
  static Uint8List encodeChunkPacket({
    required MapDimension dimension,
    required int chunkX,
    required int chunkZ,
  }) {
    // For now, flat world generation is deterministic and cheap.
    // Later: switch on dimension / generator.
    final chunk = Chunk.flatWorld(chunkX, chunkZ);
    final packet = ChunkDataPacket(chunk);
    // Return only payload (without packet ID and length)
    return packet.buildPayload();
  }
}
