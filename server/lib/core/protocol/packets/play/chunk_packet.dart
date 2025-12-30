import 'dart:typed_data';
import '../../../world/chunk/chunk.dart';
import '../../var_int.dart';
import '../../protocol_registry.dart';

/// Chunk Data and Update Light packet (Clientbound).
///
/// Ultra-optimized implementation:
/// - Pre-computed heightmaps
/// - Minimal allocations during encoding
/// - Full light data for proper rendering
class ChunkDataPacket {
  final Chunk chunk;
  final int protocolVersion;

  const ChunkDataPacket(
    this.chunk, {
    this.protocolVersion = 765, // Default: 1.20.4
  });

  static final Uint8List _fullSkyLightNibbleArray = Uint8List(2048)
    ..fillRange(0, 2048, 0xFF);

  /// Builds the complete packet ready for transmission.
  Uint8List toFramedBytes() {
    final payload = _buildPayload();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }

  Uint8List _buildPayload() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final buffer = BytesBuilder(copy: false);

    // Packet ID
    _writeVarInt(buffer, packetIds.playChunkDataAndLight);

    // Chunk X (int)
    _writeInt(buffer, chunk.x);

    // Chunk Z (int)
    _writeInt(buffer, chunk.z);

    // Heightmaps (NBT compound)
    _writeHeightmapsNbt(buffer);

    // Chunk data
    final chunkData = chunk.encodeChunkData();
    _writeVarInt(buffer, chunkData.length);
    buffer.add(chunkData);

    // Block entities count
    _writeVarInt(buffer, 0);

    // Light data
    _writeLightData(buffer);

    return buffer.toBytes();
  }

  void _writeHeightmapsNbt(BytesBuilder buffer) {
    // Simplified NBT compound for heightmaps
    // TAG_Compound start
    buffer.addByte(0x0A); // Compound tag type

    // Empty name for root compound
    buffer.addByte(0x00);
    buffer.addByte(0x00);

    // MOTION_BLOCKING long array
    buffer.addByte(0x0C); // Long array tag
    _writeNbtString(buffer, 'MOTION_BLOCKING');
    final heightmap = chunk.getHeightmapMotionBlocking();
    _writeInt(buffer, heightmap.length ~/ 8);
    buffer.add(heightmap);

    // WORLD_SURFACE long array
    buffer.addByte(0x0C);
    _writeNbtString(buffer, 'WORLD_SURFACE');
    final surface = chunk.getHeightmapWorldSurface();
    _writeInt(buffer, surface.length ~/ 8);
    buffer.add(surface);

    // End compound
    buffer.addByte(0x00);
  }

  void _writeLightData(BytesBuilder buffer) {
    // Sky light mask (BitSet)
    _writeVarInt(buffer, 1);
    _writeLong(buffer, 0x1FFFFFF); // All 25 sections have sky light

    // Block light mask (BitSet)
    _writeVarInt(buffer, 1);
    _writeLong(buffer, 0); // No block light

    // Empty sky light mask
    _writeVarInt(buffer, 1);
    _writeLong(buffer, 0);

    // Empty block light mask
    _writeVarInt(buffer, 1);
    _writeLong(buffer, 0);

    // Sky light arrays (25 sections, each 2048 bytes of full light)
    _writeVarInt(buffer, 25);
    for (int i = 0; i < 25; i++) {
      _writeVarInt(buffer, 2048);
      // Full sky light (0xFF for all nibbles)
      buffer.add(_fullSkyLightNibbleArray);
    }

    // Block light arrays (none)
    _writeVarInt(buffer, 0);
  }

  void _writeVarInt(BytesBuilder buffer, int value) {
    while ((value & ~0x7F) != 0) {
      buffer.addByte((value & 0x7F) | 0x80);
      value = value >> 7;
    }
    buffer.addByte(value & 0x7F);
  }

  void _writeInt(BytesBuilder buffer, int value) {
    buffer.addByte((value >> 24) & 0xFF);
    buffer.addByte((value >> 16) & 0xFF);
    buffer.addByte((value >> 8) & 0xFF);
    buffer.addByte(value & 0xFF);
  }

  void _writeLong(BytesBuilder buffer, int value) {
    for (int i = 7; i >= 0; i--) {
      buffer.addByte((value >> (i * 8)) & 0xFF);
    }
  }

  void _writeNbtString(BytesBuilder buffer, String value) {
    final bytes = value.codeUnits;
    buffer.addByte((bytes.length >> 8) & 0xFF);
    buffer.addByte(bytes.length & 0xFF);
    buffer.add(Uint8List.fromList(bytes));
  }
}

/// Set Center Chunk packet (Clientbound).
///
/// Tells the client which chunk to center rendering on.
class SetCenterChunkPacket {
  final int chunkX;
  final int chunkZ;
  final int protocolVersion;

  const SetCenterChunkPacket(
    this.chunkX,
    this.chunkZ, {
    this.protocolVersion = 765,
  });

  Uint8List toFramedBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final buffer = BytesBuilder(copy: false);

    // Packet ID
    _writeVarInt(buffer, packetIds.playSetCenterChunk);

    // Chunk X
    _writeVarInt(buffer, chunkX);

    // Chunk Z
    _writeVarInt(buffer, chunkZ);

    final payload = buffer.toBytes();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }

  void _writeVarInt(BytesBuilder buffer, int value) {
    while ((value & ~0x7F) != 0) {
      buffer.addByte((value & 0x7F) | 0x80);
      value = value >> 7;
    }
    buffer.addByte(value & 0x7F);
  }
}

/// Chunk Batch Start packet (Clientbound).
class ChunkBatchStartPacket {
  final int protocolVersion;
  const ChunkBatchStartPacket({this.protocolVersion = 765});

  Uint8List toFramedBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final payload = Uint8List.fromList([packetIds.playChunkBatchStart]);
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }
}

/// Chunk Batch Finished packet (Clientbound).
class ChunkBatchFinishedPacket {
  final int protocolVersion;
  const ChunkBatchFinishedPacket(this.batchSize, {this.protocolVersion = 765});

  final int batchSize;

  Uint8List toFramedBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final buffer = BytesBuilder(copy: false);

    buffer.addByte(packetIds.playChunkBatchFinished);
    _writeVarInt(buffer, batchSize);

    final payload = buffer.toBytes();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }

  void _writeVarInt(BytesBuilder buffer, int value) {
    while ((value & ~0x7F) != 0) {
      buffer.addByte((value & 0x7F) | 0x80);
      value = value >> 7;
    }
    buffer.addByte(value & 0x7F);
  }
}
