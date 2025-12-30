import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../connection/connection_state.dart';
import '../handlers/play_handler.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/packets/handshake/handshake_packet.dart';
import '../protocol/packets/login/login_start_packet.dart';
import '../session/session_manager.dart';
import 'buffer/packet_buffer.dart';
import 'buffer/send_queue.dart';
import 'packet_processor.dart';
import 'utils/network_logger.dart';

/// Enhanced connection handler with state management and optimizations.
///
/// Manages connection state transitions, player sessions, and routes packets
/// with ultra-low overhead for maximum performance.
class EnhancedConnectionHandler {
  final Socket _socket;
  final PacketBuffer _receiveBuffer;
  final SendQueue _sendQueue;
  final SessionManager _sessionManager = SessionManager();
  Timer? _processTimer;
  bool _isClosed = false;

  ConnectionState _connectionState = ConnectionState.handshake;
  String? _playerUsername;

  Function()? onClose;

  EnhancedConnectionHandler(this._socket)
    : _receiveBuffer = PacketBuffer(),
      _sendQueue = SendQueue(_socket) {
    _setupSocket();
  }

  void _setupSocket() {
    _socket.setOption(SocketOption.tcpNoDelay, true);

    _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );

    _startProcessing();
  }

  void _startProcessing() {
    _processTimer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => _processPackets(),
    );
  }

  void _onData(List<int> data) {
    if (_isClosed) return;
    _receiveBuffer.append(data);
  }

  void _processPackets() {
    if (_isClosed) return;

    int processed = 0;
    const kMaxPerCycle = 50;

    while (processed < kMaxPerCycle && !_isClosed) {
      final packetData = _receiveBuffer.tryReadPacket();
      if (packetData == null) break;

      if (!_processSinglePacket(packetData)) {
        return;
      }
      processed++;
    }
  }

  bool _processSinglePacket(Uint8List packetData) {
    try {
      final packet = Packet.fromBytes(packetData);

      // Handle handshake packet specially
      if (_connectionState == ConnectionState.handshake &&
          packet.id == PacketIds.handshakeHandshake) {
        _handleHandshake(packetData);
        return true;
      }

      // For login packets, track session after processing
      if (_connectionState == ConnectionState.login &&
          packet.id == PacketIds.loginStart) {
        _handleLoginPacket(packet);
        return true;
      }

      // Process packet based on current state
      PacketProcessor.process(
        packet,
        _sendQueue.enqueue,
        state: _connectionState,
      );

      return true;
    } catch (e) {
      if (!_isClosed) {
        NetworkLogger.error(
          'EnhancedConnectionHandler',
          'Packet processing error: $e',
        );
        _close();
      }
      return false;
    }
  }

  void _handleLoginPacket(Packet packet) {
    try {
      // Parse the login packet to extract username
      final loginPacket = LoginStartPacket.parse(packet.data);
      final username = loginPacket.playerName;

      // Process the login packet through the normal handler
      PacketProcessor.process(
        packet,
        _sendQueue.enqueue,
        state: _connectionState,
      );

      // Check if login was successful by verifying session exists
      final session = _sessionManager.getByUsername(username);
      if (session != null && session.isActive) {
        _playerUsername = username;
        _connectionState = ConnectionState.play;

        // Generate entity ID (simple counter for now)
        final entityId = session.hashCode & 0x7FFFFFFF;

        // Send Join Game packet
        final joinGamePacket = PlayHandler.createJoinGamePacket(
          session,
          entityId,
        );
        _sendQueue.enqueue(joinGamePacket);

        // Register for Keep Alive tracking
        PlayHandler.registerForKeepAlive(_socket);

        NetworkLogger.info(
          'EnhancedConnectionHandler',
          'Player $username joined the game (Entity ID: $entityId)',
        );
      }
    } catch (e) {
      NetworkLogger.error('EnhancedConnectionHandler', 'Login error: $e');
      _close();
    }
  }

  void _handleHandshake(Uint8List packetData) {
    try {
      // Use parseRaw because we're passing raw packet data with length/ID
      final handshake = HandshakePacket.parseRaw(packetData);
      NetworkLogger.debug('EnhancedConnectionHandler', 'Handshake: $handshake');

      // Transition to the requested state
      _connectionState = handshake.nextState;
    } catch (e) {
      NetworkLogger.error('EnhancedConnectionHandler', 'Handshake error: $e');
      _close();
    }
  }

  void _onError(Object error) {
    if (!_isClosed) {
      NetworkLogger.error('EnhancedConnectionHandler', 'Socket error: $error');
      _close();
    }
  }

  void _onDone() {
    if (!_isClosed) {
      NetworkLogger.debug(
        'EnhancedConnectionHandler',
        'Client disconnected: ${_socket.remoteAddress.address}:'
            '${_socket.remotePort}',
      );
      _close();
    }
  }

  void _close() {
    if (_isClosed) return;
    _isClosed = true;

    // Unregister from Keep Alive tracking
    PlayHandler.unregisterFromKeepAlive(_socket);

    // Clean up player session if exists
    if (_playerUsername != null) {
      final session = _sessionManager.getByUsername(_playerUsername!);
      if (session != null) {
        _sessionManager.removeSession(session.uuid);
      }
      _playerUsername = null;
    }

    _processTimer?.cancel();
    _receiveBuffer.clear();
    _sendQueue.clear();
    _socket.close();

    onClose?.call();
  }

  void close() {
    _close();
  }
}
