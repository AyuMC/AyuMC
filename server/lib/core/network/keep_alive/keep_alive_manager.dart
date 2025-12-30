import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../logging/server_logger.dart';
import '../../protocol/packets/play/keep_alive_packet.dart';

/// Manages Keep Alive packets for all active play connections.
///
/// Ultra-optimized implementation:
/// - Single timer for all connections (no per-connection timers)
/// - Batch processing to reduce CPU overhead
/// - Pre-computed packet bytes to minimize allocations
/// - Efficient timeout detection using timestamps
class KeepAliveManager {
  static const String _tag = 'KeepAlive';
  static final ServerLogger _logger = ServerLogger();

  /// Keep Alive interval (15 seconds - optimal for Minecraft)
  static const Duration keepAliveInterval = Duration(seconds: 15);

  /// Timeout duration (30 seconds - Minecraft default)
  static const Duration timeoutDuration = Duration(seconds: 30);

  Timer? _keepAliveTimer;
  int _keepAliveCounter = 0;

  /// Map of socket hashCode -> connection info
  final Map<int, _ConnectionKeepAlive> _connections = {};

  /// Map of socket hashCode -> protocol version
  final Map<int, int> _protocolVersions = {};

  /// Singleton instance
  static final KeepAliveManager _instance = KeepAliveManager._internal();
  factory KeepAliveManager() => _instance;
  KeepAliveManager._internal();

  /// Starts the Keep Alive system.
  void start() {
    if (_keepAliveTimer != null) return;

    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      _sendKeepAlives();
      _checkTimeouts();
    });

    _logger.info(_tag, 'Keep Alive system started (interval: 15s)');
  }

  /// Stops the Keep Alive system.
  void stop() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _connections.clear();
    _protocolVersions.clear();
    _logger.info(_tag, 'Keep Alive system stopped');
  }

  /// Registers a connection for Keep Alive tracking.
  void registerConnection(Socket socket, {int protocolVersion = 765}) {
    final id = socket.hashCode;
    _connections[id] = _ConnectionKeepAlive(
      socket: socket,
      lastSentId: 0,
      lastResponseTime: DateTime.now(),
      pendingKeepAliveId: null,
    );
    _protocolVersions[id] = protocolVersion;
  }

  /// Unregisters a connection from Keep Alive tracking.
  void unregisterConnection(Socket socket) {
    final id = socket.hashCode;
    _connections.remove(id);
    _protocolVersions.remove(id);
  }

  /// Called when a Keep Alive response is received from client.
  void onKeepAliveReceived(Socket socket, int keepAliveId) {
    final conn = _connections[socket.hashCode];
    if (conn == null) return;

    if (conn.pendingKeepAliveId == keepAliveId) {
      conn.lastResponseTime = DateTime.now();
      conn.pendingKeepAliveId = null;
    }
  }

  /// Sends Keep Alive packets to all registered connections.
  void _sendKeepAlives() {
    if (_connections.isEmpty) return;

    _keepAliveCounter++;
    final keepAliveId = _keepAliveCounter;

    // Group by protocol version for batch sending
    final packetsByVersion = <int, Uint8List>{};
    int sentCount = 0;

    for (final entry in _connections.entries) {
      final conn = entry.value;
      final protocolVersion = _protocolVersions[entry.key] ?? 765;

      // Only send if no pending Keep Alive
      if (conn.pendingKeepAliveId == null) {
        try {
          // Get or create packet for this protocol version
          final packetBytes = packetsByVersion.putIfAbsent(
            protocolVersion,
            () => KeepAliveClientboundPacket(
              keepAliveId,
              protocolVersion: protocolVersion,
            ).toFramedBytes(),
          );

          conn.socket.add(packetBytes);
          conn.lastSentId = keepAliveId;
          conn.pendingKeepAliveId = keepAliveId;
          sentCount++;
        } catch (_) {
          // Socket error - will be handled by timeout check
        }
      }
    }

    if (sentCount > 0) {
      _logger.debug(
        _tag,
        'Sent Keep Alive #$keepAliveId to $sentCount players',
      );
    }
  }

  /// Checks for timed-out connections.
  void _checkTimeouts() {
    final currentTime = DateTime.now();
    final timedOut = <int>[];

    for (final entry in _connections.entries) {
      final conn = entry.value;
      final timeSinceResponse = currentTime.difference(conn.lastResponseTime);

      if (timeSinceResponse > timeoutDuration) {
        timedOut.add(entry.key);
        _logger.warning(
          _tag,
          'Connection timed out: ${conn.socket.remoteAddress.address}',
        );

        try {
          conn.socket.close();
        } catch (_) {}
      }
    }

    for (final id in timedOut) {
      _connections.remove(id);
    }
  }

  /// Returns the number of active connections.
  int get activeConnections => _connections.length;
}

/// Internal class to track Keep Alive state per connection.
class _ConnectionKeepAlive {
  final Socket socket;
  int lastSentId;
  DateTime lastResponseTime;
  int? pendingKeepAliveId;

  _ConnectionKeepAlive({
    required this.socket,
    required this.lastSentId,
    required this.lastResponseTime,
    required this.pendingKeepAliveId,
  });
}
