import 'dart:typed_data';
import '../../packet_writer.dart';

/// Change Difficulty packet (Clientbound).
///
/// Sent by server to set world difficulty.
/// Required after Join Game packet.
class ChangeDifficultyPacket {
  final int difficulty;
  final bool difficultyLocked;

  const ChangeDifficultyPacket({
    this.difficulty = 0, // 0=Peaceful, 1=Easy, 2=Normal, 3=Hard
    this.difficultyLocked = false,
  });

  /// Builds the packet payload (without packet ID and length).
  Uint8List toBytes() {
    final writer = PacketWriter();
    
    // Difficulty (unsigned byte)
    writer.writeUnsignedByte(difficulty);
    
    // Difficulty locked (bool)
    writer.writeBool(difficultyLocked);
    
    return writer.toBytes();
  }
}


