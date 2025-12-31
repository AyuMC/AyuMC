import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../config/server_config.dart';
import '../connection/connection_state.dart';
import '../handlers/play_handler.dart';
import '../protocol/packet.dart';
import '../protocol/packet_ids.dart';
import '../protocol/protocol_registry.dart';
import '../protocol/packets/handshake/handshake_packet.dart';
import '../protocol/packets/login/login_start_packet.dart';
import '../session/session_manager.dart';
import '../world/chunk/chunk_sender.dart';
import '../world/map_dimension.dart';
import '../world/map_manager.dart';
import 'buffer/packet_buffer.dart';
import 'buffer/send_queue.dart';
import 'chat_broadcaster.dart';
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
  int _protocolVersion = 765; // Default: 1.20.4
  String? _disconnectReason;
  DateTime? _connectionStartTime;

  Function()? onClose;

  EnhancedConnectionHandler(this._socket)
    : _receiveBuffer = PacketBuffer(),
      _sendQueue = SendQueue(_socket) {
    _setupSocket();
  }

  void _setupSocket() {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _connectionStartTime = DateTime.now();

    final clientInfo = '${_socket.remoteAddress.address}:${_socket.remotePort}';
    NetworkLogger.debug(
      'EnhancedConnectionHandler',
      'New connection from $clientInfo',
    );

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
      // For play state, we need to pass session information
      if (_connectionState == ConnectionState.play && _playerUsername != null) {
        final session = _sessionManager.getByUsername(_playerUsername!);
        if (session != null) {
          // Use PlayHandler directly for play packets
          PlayHandler.handlePacket(
            packet,
            _socket,
            _sendQueue.enqueue,
            session,
          );
        }
      } else {
        // For other states, use PacketProcessor
        PacketProcessor.process(
          packet,
          _sendQueue.enqueue,
          state: _connectionState,
          socket: _socket,
        );
      }

      return true;
    } catch (e) {
      if (!_isClosed) {
        final clientInfo =
            '${_socket.remoteAddress.address}:${_socket.remotePort}';
        NetworkLogger.error(
          'EnhancedConnectionHandler',
          'Packet processing error from $clientInfo: $e',
        );
        _disconnectReason = 'Packet processing error: $e';
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
        // Store protocol version in session
        session.protocolVersion = _protocolVersion;
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
        PlayHandler.registerForKeepAlive(_socket, session.protocolVersion);

        // Register for chat broadcasting
        ChatBroadcaster.registerPlayer(session.uuid, _socket);

        // Send spawn position and (optionally) initial chunks
        _sendInitialWorldData(session);

        // Log player join with full details
        final clientInfo =
            '${_socket.remoteAddress.address}:${_socket.remotePort}';
        final sessionManager = SessionManager();
        final onlineCount = sessionManager.sessionCount;
        final protocolName = _getProtocolVersionName(_protocolVersion);
        final connectionDuration = _connectionStartTime != null
            ? DateTime.now().difference(_connectionStartTime!).inMilliseconds
            : 0;

        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '✓ Player Joined: $username',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  ├─ Entity ID: $entityId',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  ├─ UUID: ${session.uuid}',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  ├─ Protocol: $protocolName (v$_protocolVersion)',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  ├─ Address: $clientInfo',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  ├─ Connection Time: ${connectionDuration}ms',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '  └─ Online Players: $onlineCount/5000',
        );
        NetworkLogger.info(
          'EnhancedConnectionHandler',
          '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
        );
      }
    } catch (e) {
      NetworkLogger.error('EnhancedConnectionHandler', 'Login error: $e');
      _close();
    }
  }

  void _sendInitialWorldData(dynamic session) {
    // Get spawn position from MapManager
    final mapManager = MapManager();
    final (spawnX, spawnY, spawnZ) = mapManager.getSpawnPosition(
      MapDimension.overworld,
    );

    // Set player position to spawn
    session.x = spawnX.toDouble();
    session.y = spawnY.toDouble();
    session.z = spawnZ.toDouble();

    // Send spawn position packet
    final spawnPacket = PlayHandler.createSpawnPositionPacket(
      x: spawnX,
      y: spawnY,
      z: spawnZ,
      protocolVersion: session.protocolVersion,
    );
    _sendQueue.enqueue(
      Packet(
        id: ProtocolRegistry.getPacketIds(
          session.protocolVersion,
        ).playSetDefaultSpawnPosition,
        data: spawnPacket.toBytes(),
      ),
    );

    // Send player position packet
    final posPacket = PlayHandler.createSyncPositionPacket(session, 0);
    _sendQueue.enqueue(
      Packet(
        id: ProtocolRegistry.getPacketIds(
          session.protocolVersion,
        ).playPlayerPosition,
        data: posPacket.toBytes(),
      ),
    );

    if (ServerConfig.kEnableChunkStreaming) {
      // Use SendQueue for optimized batching (pressure on client, not server)
      ChunkSender.sendInitialChunks(
        _sendQueue,
        session.x,
        session.z,
        dimension: MapDimension.overworld,
        viewDistance: ServerConfig.kInitialChunkViewDistance,
        protocolVersion: session.protocolVersion,
      );
    }
  }

  void _handleHandshake(Uint8List packetData) {
    try {
      // Use parseRaw because we're passing raw packet data with length/ID
      final handshake = HandshakePacket.parseRaw(packetData);
      _protocolVersion = handshake.protocolVersion;
      NetworkLogger.debug(
        'EnhancedConnectionHandler',
        'Handshake: protocol=$_protocolVersion, nextState=${handshake.nextState}',
      );

      // Transition to the requested state
      _connectionState = handshake.nextState;
    } catch (e) {
      NetworkLogger.error('EnhancedConnectionHandler', 'Handshake error: $e');
      _close();
    }
  }

  void _onError(Object error) {
    if (!_isClosed) {
      final clientInfo =
          '${_socket.remoteAddress.address}:${_socket.remotePort}';
      final errorType = error.runtimeType.toString();
      final errorMessage = error.toString();

      NetworkLogger.error(
        'EnhancedConnectionHandler',
        'Socket error from $clientInfo: [$errorType] $errorMessage',
      );

      _disconnectReason = 'Socket error: $errorMessage';
      _close();
    }
  }

  void _onDone() {
    if (!_isClosed) {
      _disconnectReason = _disconnectReason ?? 'Client disconnected normally';
      _close();
    }
  }

  void _close() {
    if (_isClosed) return;
    _isClosed = true;

    final clientInfo = '${_socket.remoteAddress.address}:${_socket.remotePort}';
    final connectionDuration = _connectionStartTime != null
        ? DateTime.now().difference(_connectionStartTime!).inMilliseconds
        : 0;

    // Unregister from Keep Alive tracking
    PlayHandler.unregisterFromKeepAlive(_socket);

    // Unregister from chat broadcasting
    if (_playerUsername != null) {
      final session = _sessionManager.getByUsername(_playerUsername!);
      if (session != null) {
        ChatBroadcaster.unregisterPlayer(session.uuid);
      }
    }

    // Log player disconnect with details
    if (_playerUsername != null) {
      final session = _sessionManager.getByUsername(_playerUsername!);
      final sessionManager = SessionManager();
      final onlineCount =
          sessionManager.sessionCount - 1; // -1 because we're disconnecting

      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '✗ Player Left: $_playerUsername',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '  ├─ Reason: ${_disconnectReason ?? "Unknown"}',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '  ├─ Address: $clientInfo',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '  ├─ Session Duration: ${(connectionDuration / 1000).toStringAsFixed(2)}s',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '  └─ Online Players: $onlineCount/5000',
      );
      NetworkLogger.info(
        'EnhancedConnectionHandler',
        '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      );

      // Clean up player session
      if (session != null) {
        _sessionManager.removeSession(session.uuid);
      }
      _playerUsername = null;
    } else {
      // Connection closed before login
      NetworkLogger.debug(
        'EnhancedConnectionHandler',
        'Connection closed from $clientInfo (before login) - Reason: ${_disconnectReason ?? "Unknown"}',
      );
    }

    _processTimer?.cancel();
    _receiveBuffer.clear();
    _sendQueue.clear();
    _socket.close();

    onClose?.call();
  }

  /// Gets human-readable protocol version name.
  String _getProtocolVersionName(int protocolVersion) {
    return switch (protocolVersion) {
      765 => '1.20.4',
      766 => '1.20.6',
      763 => '1.20.1',
      769 => '1.20.2',
      _ => 'Unknown ($protocolVersion)',
    };
  }

  void close() {
    _close();
  }
}
