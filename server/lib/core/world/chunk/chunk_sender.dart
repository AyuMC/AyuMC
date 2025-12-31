import 'dart:async';
import '../../config/server_config.dart';
import '../../logging/server_logger.dart';
import '../../protocol/packet.dart';
import '../../protocol/protocol_registry.dart';
import '../../protocol/var_int.dart';
import '../../protocol/packets/play/chunk_packet.dart';
import '../map_dimension.dart';
import '../map_manager.dart';
import '../../network/buffer/send_queue.dart';

/// Handles sending chunks to players.
///
/// Ultra-optimized implementation:
/// - Uses SendQueue for batching (reduces server load)
/// - Pre-encoded chunks from isolate pool (multi-threaded)
/// - LRU cache for encoded chunks (zero re-encoding)
/// - Async-friendly for non-blocking chunk loading
/// - Pressure shifted to client (chunk processing on client side)
class ChunkSender {
  static const String _tag = 'ChunkSender';
  static final ServerLogger _logger = ServerLogger();

  /// Default view distance in chunks
  static const int kDefaultViewDistance = 8;

  /// Sends initial chunks to a player at the given position.
  ///
  /// Ultra-optimized: Uses SendQueue, pre-encoded chunks, and async loading.
  /// Sends in optimal order:
  /// 1. Set Center Chunk
  /// 2. Chunk Batch Start
  /// 3. All chunks (pre-encoded, from isolate pool)
  /// 4. Chunk Batch Finished
  static Future<void> sendInitialChunks(
    SendQueue sendQueue,
    double playerX,
    double playerZ, {
    MapDimension dimension = MapDimension.overworld,
    int viewDistance = kDefaultViewDistance,
    int protocolVersion = 765, // Default: 1.20.4
  }) async {
    if (!ServerConfig.kEnableChunkStreaming) {
      _logger.warning(
        _tag,
        'Chunk streaming is disabled (ServerConfig.kEnableChunkStreaming=false).',
      );
      return;
    }

    final mapManager = MapManager();
    final centerChunkX = (playerX / 16).floor();
    final centerChunkZ = (playerZ / 16).floor();

    // 1. Set Center Chunk
    final centerPacket = SetCenterChunkPacket(
      centerChunkX,
      centerChunkZ,
      protocolVersion: protocolVersion,
    );
    // Extract payload from toFramedBytes (skip length, keep payload)
    final centerFramed = centerPacket.toFramedBytes();
    final lengthSize = VarInt.decodeSize(centerFramed, 0);
    final centerPayload = centerFramed.sublist(lengthSize);
    sendQueue.enqueue(
      Packet(
        id: ProtocolRegistry.getPacketIds(protocolVersion).playSetCenterChunk,
        data: centerPayload,
      ),
    );

    // 2. Chunk Batch Start
    final batchStart = ChunkBatchStartPacket(protocolVersion: protocolVersion);
    final batchStartFramed = batchStart.toFramedBytes();
    final batchStartLengthSize = VarInt.decodeSize(batchStartFramed, 0);
    final batchStartPayload = batchStartFramed.sublist(batchStartLengthSize);
    sendQueue.enqueue(
      Packet(
        id: ProtocolRegistry.getPacketIds(protocolVersion).playChunkBatchStart,
        data: batchStartPayload,
      ),
    );

    // 3. Collect chunk positions in spiral pattern (center first)
    final chunkPositions = <(int x, int z)>[];
    for (int radius = 0; radius <= viewDistance; radius++) {
      if (radius == 0) {
        chunkPositions.add((centerChunkX, centerChunkZ));
      } else {
        // Add ring of chunks at this radius
        for (int dx = -radius; dx <= radius; dx++) {
          for (int dz = -radius; dz <= radius; dz++) {
            if (dx.abs() == radius || dz.abs() == radius) {
              chunkPositions.add((centerChunkX + dx, centerChunkZ + dz));
            }
          }
        }
      }
    }

    // 4. Load and send chunks asynchronously (using pre-encoded cache + isolate pool)
    int chunksSent = 0;
    final encodeFutures = <Future<void>>[];

    for (final (chunkX, chunkZ) in chunkPositions) {
      // Get pre-encoded chunk packet (uses isolate pool + LRU cache)
      // Returns payload without packet ID (protocol-aware ID added here)
      final encodeFuture = mapManager
          .getOrEncodeChunkPacket(dimension, chunkX, chunkZ)
          .then((transferableData) {
            // Convert TransferableTypedData to Uint8List (payload only, no packet ID)
            final payloadBytes = transferableData.materialize().asUint8List();

            // Create packet with protocol-aware packet ID
            final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
            sendQueue.enqueue(
              Packet(id: packetIds.playChunkDataAndLight, data: payloadBytes),
            );
            chunksSent++;
          })
          .catchError((e) {
            _logger.error(
              _tag,
              'Failed to encode/send chunk ($chunkX, $chunkZ): $e',
            );
          });

      encodeFutures.add(encodeFuture);
    }

    // Wait for all chunks to be encoded and queued (non-blocking, uses isolates)
    await Future.wait(encodeFutures);

    // 5. Chunk Batch Finished
    final batchFinished = ChunkBatchFinishedPacket(
      chunksSent,
      protocolVersion: protocolVersion,
    );
    sendQueue.enqueue(
      Packet(
        id: ProtocolRegistry.getPacketIds(
          protocolVersion,
        ).playChunkBatchFinished,
        data: batchFinished.toFramedBytes(),
      ),
    );

    _logger.debug(
      _tag,
      'Queued $chunksSent chunks for player at ($centerChunkX, $centerChunkZ)',
    );
  }
}
