import 'dart:convert';
import 'dart:typed_data';
import '../../packet_reader.dart';
import '../../packet_writer.dart';
import '../../protocol_registry.dart';
import '../../var_int.dart';

/// Chat Message packet from client (Serverbound).
///
/// Parses incoming chat messages from players.
class ChatMessageServerboundPacket {
  final String message;
  final DateTime timestamp;
  final int salt;
  final bool signedPreview;

  const ChatMessageServerboundPacket({
    required this.message,
    required this.timestamp,
    required this.salt,
    this.signedPreview = false,
  });

  /// Parses a chat message packet from raw bytes (payload only).
  factory ChatMessageServerboundPacket.parse(Uint8List data) {
    final reader = PacketReader(data);
    final message = reader.readString();
    final timestamp = DateTime.fromMillisecondsSinceEpoch(reader.readLong());
    final salt = reader.readLong();
    final signedPreview = reader.readBool();

    return ChatMessageServerboundPacket(
      message: message,
      timestamp: timestamp,
      salt: salt,
      signedPreview: signedPreview,
    );
  }
}

/// Player Chat Message packet (Clientbound).
///
/// Sends chat messages to all players.
class PlayerChatMessagePacket {
  final String sender;
  final String message;
  final DateTime timestamp;
  final int protocolVersion;

  const PlayerChatMessagePacket({
    required this.sender,
    required this.message,
    required this.timestamp,
    this.protocolVersion = 765,
  });

  /// Builds the packet bytes with minimal allocations.
  Uint8List toBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final writer = PacketWriter();

    writer.writeVarInt(packetIds.playChatMessage);

    // Chat message JSON
    final chatJson = jsonEncode({'text': '<$sender> $message'});
    writer.writeString(chatJson);

    // Position (0 = chat, 1 = system, 2 = game info)
    writer.writeByte(0);

    // Sender UUID (zero UUID for offline mode)
    writer.writeLong(0);
    writer.writeLong(0);

    // Sender display name (JSON)
    final displayNameJson = jsonEncode({'text': sender});
    writer.writeString(displayNameJson);

    // Team name (empty for no team)
    writer.writeString('');

    // Timestamp
    writer.writeLong(timestamp.millisecondsSinceEpoch);

    // Salt
    writer.writeLong(0);

    // Signature (empty for unsigned)
    writer.writeVarInt(0);

    // Message count
    writer.writeVarInt(1);

    // Acknowledged message signatures (empty)
    writer.writeVarInt(0);

    return writer.toBytes();
  }

  /// Creates a framed packet ready for transmission.
  Uint8List toFramedBytes() {
    final payload = toBytes();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }
}

/// System Chat Message packet (Clientbound).
///
/// Sends system messages (server announcements, etc.).
class SystemChatMessagePacket {
  final String message;
  final bool overlay;
  final int protocolVersion;

  const SystemChatMessagePacket({
    required this.message,
    this.overlay = false,
    this.protocolVersion = 765,
  });

  /// Builds the packet bytes.
  Uint8List toBytes() {
    final packetIds = ProtocolRegistry.getPacketIds(protocolVersion);
    final writer = PacketWriter();

    // System chat uses same packet ID but different format
    writer.writeVarInt(packetIds.playChatMessage);

    // Chat message JSON
    final chatJson = jsonEncode({'text': message});
    writer.writeString(chatJson);

    // Position (1 = system message)
    writer.writeByte(1);

    return writer.toBytes();
  }

  /// Creates a framed packet ready for transmission.
  Uint8List toFramedBytes() {
    final payload = toBytes();
    final lengthBytes = VarInt.encode(payload.length);

    final result = Uint8List(lengthBytes.length + payload.length);
    result.setAll(0, lengthBytes);
    result.setAll(lengthBytes.length, payload);

    return result;
  }
}
