import '../protocol/packet.dart';
import '../protocol/packets/play/join_game_packet.dart';
import '../session/player_session.dart';

/// Handles the Minecraft Play protocol phase.
///
/// This handler manages gameplay packets for active players.
class PlayHandler {
  PlayHandler._();

  /// Sends the Join Game packet to a newly connected player.
  ///
  /// This is the first packet sent when a player transitions to Play state.
  static Packet createJoinGamePacket(PlayerSession session, int entityId) {
    final joinPacket = JoinGamePacket(
      entityId: entityId,
      isHardcore: false,
      dimensionNames: [
        'minecraft:overworld',
        'minecraft:the_nether',
        'minecraft:the_end',
      ],
      maxPlayers: 5000,
      viewDistance: 10,
      simulationDistance: 10,
      reducedDebugInfo: false,
      enableRespawnScreen: true,
      doLimitedCrafting: false,
      dimensionType: 'minecraft:overworld',
      dimensionName: 'minecraft:overworld',
      hashedSeed: 0,
      gameMode: 1, // Creative mode
      previousGameMode: -1,
      isDebug: false,
      isFlat: false,
      hasDeathLocation: false,
    );

    final data = joinPacket.toBytes();
    return Packet(id: 0x28, data: data);
  }

  /// Handles incoming play packets.
  static void handlePacket(
    Packet packet,
    void Function(Packet) sendResponse,
    PlayerSession session,
  ) {
    // TODO: Handle play packets (movement, chat, etc.)
    print('[PlayHandler] Received play packet: ${packet.id}');
  }
}
