import 'dart:typed_data';
import '../../packet_writer.dart';

/// Player Abilities packet (Clientbound).
///
/// Sent by server to set player abilities (flying, creative mode, etc.).
/// Required after Join Game packet.
class PlayerAbilitiesPacket {
  final int flags;
  final double flyingSpeed;
  final double fieldOfViewModifier;

  const PlayerAbilitiesPacket({
    this.flags = 0x02, // Creative mode: can fly, is flying
    this.flyingSpeed = 0.05,
    this.fieldOfViewModifier = 0.1,
  });

  /// Builds the packet payload (without packet ID and length).
  Uint8List toBytes() {
    final writer = PacketWriter();
    
    // Flags byte:
    // Bit 0: Invulnerable
    // Bit 1: Flying
    // Bit 2: Allow Flying
    // Bit 3: Creative Mode (Instant Break)
    writer.writeByte(flags);
    
    // Flying speed (float)
    writer.writeFloat(flyingSpeed);
    
    // Field of view modifier (float)
    writer.writeFloat(fieldOfViewModifier);
    
    return writer.toBytes();
  }
}

