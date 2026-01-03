import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../protocol/packet.dart';
import '../../protocol/var_int.dart';
import '../utils/connection_error_handler.dart';

class SendQueue {
  final Socket _socket;
  final List<Uint8List> _queue = [];
  bool _isSending = false;
  bool _isClosed = false;
  static const int _kMaxQueueSize = 1000;
  SendQueue(this._socket);

  void enqueue(Packet packet) {
    if (_isClosed || _queue.length >= _kMaxQueueSize) {
      return;
    }

    try {
      final bytes = packet.toBytes();

      // Validate packet bytes are not empty
      if (bytes.isEmpty) {
        throw Exception('Packet bytes are empty');
      }

      // Debug: Log ALL packets being sent (critical for debugging)
      final packetIdSize = VarInt.getSize(packet.id);
      final packetLength = packetIdSize + packet.data.length;
      final packetLengthSize = VarInt.getSize(packetLength);
      final expectedTotal = packetLengthSize + packetLength;
      
      // Get packet name for better debugging
      String packetName = _getPacketName(packet.id);
      
      print(
        '[SendQueue] Sending packet: $packetName\n'
        '  Packet ID: ${packet.id} (0x${packet.id.toRadixString(16)})\n'
        '  Packet ID size: $packetIdSize bytes\n'
        '  Data length: ${packet.data.length} bytes\n'
        '  Packet length (ID+data): $packetLength bytes\n'
        '  Length VarInt size: $packetLengthSize bytes\n'
        '  Expected total: $expectedTotal bytes\n'
        '  Actual total: ${bytes.length} bytes\n'
        '  First 30 bytes: ${bytes.sublist(0, bytes.length > 30 ? 30 : bytes.length).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );
      
      // Verify packet can be read back (critical check)
      try {
        final testPacket = Packet.fromBytes(bytes);
        if (testPacket.id != packet.id) {
          throw Exception(
            'Packet ID mismatch after encoding: expected ${packet.id}, got ${testPacket.id}',
          );
        }
        if (testPacket.data.length != packet.data.length) {
          throw Exception(
            'Packet data length mismatch: expected ${packet.data.length}, got ${testPacket.data.length}',
          );
        }
        print('[SendQueue] ✓ $packetName encoding verification passed');
      } catch (e) {
        print('[SendQueue] ✗ ERROR: $packetName encoding verification failed: $e');
        rethrow;
      }

      _queue.add(bytes);

      if (!_isSending) {
        _processQueue();
      }
    } catch (e) {
      // Log error but don't crash - this helps identify encoding issues
      print('[SendQueue] Error encoding packet: $e');
      rethrow;
    }
  }

  Future<void> _processQueue() async {
    if (_isClosed || _queue.isEmpty || _isSending) return;

    _isSending = true;

    try {
      // CRITICAL: Send packets one by one, not in batches
      // This ensures each packet is sent immediately and separately
      while (_queue.isNotEmpty && !_isClosed) {
        final packetBytes = _queue.removeAt(0);

        try {
          // Validate packet bytes before sending
          if (packetBytes.isEmpty) {
            throw Exception('Cannot send empty packet');
          }

          // Send packet immediately
          _socket.add(packetBytes);
          
          // CRITICAL: Wait a tiny bit to ensure packet is flushed before sending next
          // This prevents packets from being combined in TCP buffer
          // In Dart, socket.add() queues data but doesn't guarantee immediate flush
          // A small delay ensures proper packet boundaries
          await Future.delayed(Duration(microseconds: 100));
        } on SocketException {
          // Connection closed or write failed - this is normal when client disconnects
          _closeQueue();
          return;
        } catch (e) {
          if (ConnectionErrorHandler.isConnectionError(e)) {
            _closeQueue();
            return;
          }
          // Log unexpected errors for debugging
          print('[SendQueue] Unexpected error sending packet: $e');
          rethrow;
        }

        // Yield to event loop after each packet to prevent blocking
        if (_queue.isNotEmpty) {
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      _handleError(e);
    } finally {
      _isSending = false;
    }
  }

  // REMOVED: _extractBatch and _sendBatch are no longer used
  // Packets are now sent one by one in _processQueue to ensure proper boundaries

  void _handleError(Object error) {
    if (!_isClosed) {
      _closeQueue();
    }
  }

  void _closeQueue() {
    _isClosed = true;
    _queue.clear();
  }

  // REMOVED: _combineBytes is no longer used
  // Minecraft protocol requires packets to be sent separately, not combined
  // Each packet must be sent individually to maintain proper packet boundaries

  void clear() {
    _closeQueue();
  }

  /// Helper to get packet name for debugging
  static String _getPacketName(int packetId) {
    switch (packetId) {
      case 0x28:
        return 'Join Game';
      case 0x4E:
      case 0x56:
        return 'Set Default Spawn Position';
      case 0x0C:
        return 'Change Difficulty';
      case 0x34:
      case 0x35:
        return 'Player Abilities';
      case 0x3E:
      case 0x40:
        return 'Player Position';
      case 0x24:
      case 0x27:
        return 'Chunk Data';
      default:
        return 'Unknown (0x${packetId.toRadixString(16)})';
    }
  }
}
