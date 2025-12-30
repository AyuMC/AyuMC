import 'dart:io';
import 'dart:typed_data';

import '../../logging/server_logger.dart';
import '../../protocol/packets/play/chunk_packet.dart';
import '../map_dimension.dart';
import '../map_manager.dart';
import 'chunk.dart';

/// Handles sending chunks to players.
///
/// Ultra-optimized implementation:
/// - Batch chunk sending
/// - Priority-based loading (closest chunks first)
/// - Async-friendly for multi-threaded use
class ChunkSender {
  static const String _tag = 'ChunkSender';
  static final ServerLogger _logger = ServerLogger();

  /// Default view distance in chunks
  static const int kDefaultViewDistance = 8;

  /// Sends initial chunks to a player at the given position.
  ///
  /// Sends in optimal order:
  /// 1. Set Center Chunk
  /// 2. Chunk Batch Start
  /// 3. All chunks
  /// 4. Chunk Batch Finished
  static void sendInitialChunks(
    Socket socket,
    double playerX,
    double playerZ, {
    MapDimension dimension = MapDimension.overworld,
    int viewDistance = kDefaultViewDistance,
  }) {
    final mapManager = MapManager();
    final centerChunkX = (playerX / 16).floor();
    final centerChunkZ = (playerZ / 16).floor();

    // 1. Set Center Chunk
    final centerPacket = SetCenterChunkPacket(centerChunkX, centerChunkZ);
    _sendBytes(socket, centerPacket.toFramedBytes());

    // 2. Chunk Batch Start
    final batchStart = ChunkBatchStartPacket();
    _sendBytes(socket, batchStart.toFramedBytes());

    // 3. Send chunks in spiral pattern (center first)
    int chunksSent = 0;
    final chunksToSend = <Chunk>[];

    for (int radius = 0; radius <= viewDistance; radius++) {
      if (radius == 0) {
        chunksToSend.add(
          mapManager.getOrGenerateChunk(dimension, centerChunkX, centerChunkZ),
        );
      } else {
        // Add ring of chunks at this radius
        for (int dx = -radius; dx <= radius; dx++) {
          for (int dz = -radius; dz <= radius; dz++) {
            if (dx.abs() == radius || dz.abs() == radius) {
              chunksToSend.add(
                mapManager.getOrGenerateChunk(
                  dimension,
                  centerChunkX + dx,
                  centerChunkZ + dz,
                ),
              );
            }
          }
        }
      }
    }

    // Send all chunks
    for (final chunk in chunksToSend) {
      final chunkPacket = ChunkDataPacket(chunk);
      _sendBytes(socket, chunkPacket.toFramedBytes());
      chunksSent++;
    }

    // 4. Chunk Batch Finished
    final batchFinished = ChunkBatchFinishedPacket(chunksSent);
    _sendBytes(socket, batchFinished.toFramedBytes());

    _logger.debug(
      _tag,
      'Sent $chunksSent chunks to player at ($centerChunkX, $centerChunkZ)',
    );
  }

  /// Sends raw bytes to a socket.
  static void _sendBytes(Socket socket, Uint8List bytes) {
    try {
      socket.add(bytes);
    } catch (e) {
      _logger.error(_tag, 'Failed to send chunk: $e');
    }
  }
}

