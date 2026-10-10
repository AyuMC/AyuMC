import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'buffer.dart';
import 'flat_chunk.dart';
import 'offline_uuid.dart';
import 'play_session.dart';
import 'primitives.dart';

/// Why a connection was closed. Useful in tests and logs.
enum ProtocolCloseReason { completed, malformed, unsupportedState, remoteClosed, timedOut }

typedef PrimitiveListener = void Function(String id, Map<String, Object?> data);
typedef PrimitiveInterest = bool Function(String id);

/// Minecraft 1.8.9 connections.
///
/// Offline mode sends Login Success and the minimum play-state packets for
/// a client to leave the "downloading terrain" screen onto a single stone
/// pad. Online mode is not implemented: with [offlineMode] false, login
/// start is refused. No public gameplay event is defined here.
final class ProtocolEndpoint {
  ProtocolEndpoint({
    required this.versionName,
    required this.protocolVersion,
    required this.description,
    this.maxPlayers = 5000,
    this.offlineMode = true,
    this.onPrimitive,
    this.interestedIn,
    this.maxFrameBytes = 32767,
    this.keepAliveInterval = const Duration(seconds: 15),
    this.keepAliveTimeout = const Duration(seconds: 30),
  });

  final String versionName;
  final int protocolVersion;
  final String description;
  final int maxPlayers;

  /// When false, a login start is rejected. Encryption is not implemented.
  final bool offlineMode;
  final PrimitiveListener? onPrimitive;

  /// When set, high-frequency primitives are skipped unless this returns true.
  final PrimitiveInterest? interestedIn;
  final int maxFrameBytes;
  final Duration keepAliveInterval;
  final Duration keepAliveTimeout;

  ServerSocket? _server;
  final Set<_Connection> _connections = {};
  int _online = 0;
  int _nextEntityId = 1;
  late final Uint8List _spawnChunk = flatStonePadChunk(chunkX: 0, chunkZ: 0);

  int get port => _server?.port ?? 0;
  int get connections => _connections.length;

  /// Connections that have entered the play state.
  List<PlaySession> get sessions => [
        for (final connection in _connections)
          if (connection.session != null) connection.session!,
      ];

  bool wants(String id) => onPrimitive != null && (interestedIn?.call(id) ?? true);

  Future<void> bind({InternetAddress? address, int port = 25565}) async {
    if (_server != null) throw StateError('endpoint already bound');
    _server = await ServerSocket.bind(address ?? InternetAddress.loopbackIPv4, port);
    _server!.listen(_accept, onError: (Object _) {});
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final connection in List.of(_connections)) {
      await connection.close(ProtocolCloseReason.completed);
    }
  }

  void _accept(Socket socket) {
    final connection = _Connection(socket, this);
    _connections.add(connection);
    _online++;
    connection.done.future.whenComplete(() {
      _connections.remove(connection);
      _online--;
    });
  }

  void _emit(String id, Map<String, Object?> data) => onPrimitive?.call(id, data);

  Map<String, Object?> get _status => {
        'version': {'name': versionName, 'protocol': protocolVersion},
        'players': {'max': maxPlayers, 'online': _online},
        'description': {'text': description},
      };
}

enum _Phase { handshake, status, login, play }

final _namePattern = RegExp(r'^[A-Za-z0-9_]{1,16}$');

final class _Connection {
  _Connection(this._socket, this._endpoint) {
    _subscription = _socket.listen(_onData, onError: (_) => close(ProtocolCloseReason.remoteClosed), onDone: () => close(ProtocolCloseReason.remoteClosed));
  }

  final Socket _socket;
  final ProtocolEndpoint _endpoint;
  final PacketBuffer _inbound = PacketBuffer();
  late final StreamSubscription<List<int>> _subscription;
  final Completer<void> done = Completer<void>();
  _Phase _phase = _Phase.handshake;
  bool _closed = false;
  Future<void>? _shutdown;
  PlaySession? session;
  Timer? _keepAliveTimer;
  int _keepAliveId = 0;
  bool _awaitingKeepAlive = false;
  DateTime? _keepAliveSentAt;

  void _onData(List<int> chunk) {
    _inbound.add(chunk);
    try {
      while (!_closed) {
        final frame = _inbound.readFrame(maxFrameBytes: _endpoint.maxFrameBytes);
        if (frame == null) return;
        _handle(PacketBuffer()..add(frame));
      }
    } on PacketFormatException {
      close(ProtocolCloseReason.malformed);
    }
  }

  void _handle(PacketBuffer packet) {
    final id = packet.readVarInt();
    switch (_phase) {
      case _Phase.handshake:
        if (id != 0x00) {
          close(ProtocolCloseReason.malformed);
          return;
        }
        final announced = packet.readVarInt();
        final address = packet.readString();
        final port = packet.readUnsignedShort();
        final next = packet.readVarInt();
        _endpoint._emit(ProtocolPrimitive.handshake, {
          'protocol': announced,
          'address': address,
          'port': port,
          'nextState': next,
        });
        if (announced != _endpoint.protocolVersion) {
          close(ProtocolCloseReason.unsupportedState);
          return;
        }
        if (next == 1) {
          _phase = _Phase.status;
        } else if (next == 2) {
          _phase = _Phase.login;
        } else {
          close(ProtocolCloseReason.unsupportedState);
        }
      case _Phase.status:
        if (id == 0x00) {
          _socket.add(encodePacket(0x00, encodeString(jsonEncode(_endpoint._status))));
        } else if (id == 0x01) {
          _socket.add(encodePacket(0x01, encodeLong(packet.readLong())));
        } else {
          close(ProtocolCloseReason.malformed);
        }
      case _Phase.login:
        if (id != 0x00) {
          close(ProtocolCloseReason.malformed);
          return;
        }
        final name = packet.readString(maxBytes: 48);
        if (!_namePattern.hasMatch(name)) {
          close(ProtocolCloseReason.malformed, farewell: _disconnect('invalid name'));
          return;
        }
        _endpoint._emit(ProtocolPrimitive.login, {'name': name, 'protocol': _endpoint.protocolVersion});
        if (!_endpoint.offlineMode) {
          close(ProtocolCloseReason.unsupportedState, farewell: _disconnect('online authentication is not implemented'));
          return;
        }
        _enterPlay(name);
      case _Phase.play:
        _handlePlay(id, packet);
    }
  }

  void _enterPlay(String name) {
    final uuid = offlinePlayerUuid(name);
    session = PlaySession(
      entityId: _endpoint._nextEntityId++,
      name: name,
      uuid: uuid,
      x: PlaySession.spawnX,
      y: PlaySession.spawnY,
      z: PlaySession.spawnZ,
    );
    final player = session!;
    _socket.add(encodePacket(0x02, [...encodeString(uuid), ...encodeString(name)]));
    _phase = _Phase.play;
    _socket.add(encodePacket(0x01, [
      ...encodeInt(player.entityId),
      0, // survival
      0, // overworld
      1, // easy
      _endpoint.maxPlayers < 1 ? 1 : (_endpoint.maxPlayers > 255 ? 255 : _endpoint.maxPlayers),
      ...encodeString('flat'),
      0, // reduced debug info
    ]));
    _socket.add(encodePacket(0x05, encodeBlockPosition(8, 15, 8)));
    _socket.add(encodePacket(0x39, [0, ...encodeFloat(0.05), ...encodeFloat(0.1)]));
    _socket.add(encodePacket(0x08, [
      ...encodeDouble(player.x),
      ...encodeDouble(player.y),
      ...encodeDouble(player.z),
      ...encodeFloat(0),
      ...encodeFloat(0),
      0,
    ]));
    _socket.add(_endpoint._spawnChunk);
    _socket.add(encodePacket(0x03, [...encodeLong(0), ...encodeLong(6000)]));
    _socket.add(encodePacket(0x06, [...encodeFloat(20), ...encodeVarInt(20), ...encodeFloat(5)]));
    _endpoint._emit(ProtocolPrimitive.playJoined, player.toFields());
    _keepAliveTimer = Timer.periodic(_endpoint.keepAliveInterval, _onKeepAlive);
  }

  void _onKeepAlive(Timer timer) {
    if (_closed || _phase != _Phase.play) return;
    if (_awaitingKeepAlive &&
        _keepAliveSentAt != null &&
        DateTime.now().difference(_keepAliveSentAt!) > _endpoint.keepAliveTimeout) {
      close(ProtocolCloseReason.timedOut, farewell: _disconnect('timed out'));
      return;
    }
    _keepAliveId = (_keepAliveId + 1) & 0x7fffffff;
    _awaitingKeepAlive = true;
    _keepAliveSentAt = DateTime.now();
    _socket.add(encodePacket(0x00, encodeVarInt(_keepAliveId)));
  }

  void _handlePlay(int id, PacketBuffer packet) {
    final player = session;
    if (player == null) {
      close(ProtocolCloseReason.malformed);
      return;
    }
    switch (id) {
      case 0x00:
        final echoed = packet.readVarInt();
        if (echoed == _keepAliveId) _awaitingKeepAlive = false;
        return;
      case 0x03:
        player.onGround = packet.readBool();
        return;
      case 0x04:
      case 0x06:
        _applyPosition(
          player,
          packet.readDouble(),
          packet.readDouble(),
          packet.readDouble(),
          yaw: id == 0x06 ? packet.readFloat() : null,
          pitch: id == 0x06 ? packet.readFloat() : null,
          onGround: packet.readBool(),
        );
        return;
      case 0x05:
        player.yaw = packet.readFloat();
        player.pitch = packet.readFloat();
        player.onGround = packet.readBool();
        _emitPosition(player);
        return;
      case 0x15:
        packet.readString();
        if (packet.length < 4) throw const PacketFormatException('truncated client settings');
        return;
      default:
        return;
    }
  }

  void _applyPosition(PlaySession player, double x, double y, double z, {double? yaw, double? pitch, required bool onGround}) {
    if (!_finite(x) || !_finite(y) || !_finite(z) || x.abs() > 3e7 || z.abs() > 3e7 || y < -64 || y > 4096) {
      return;
    }
    player
      ..x = x
      ..y = y
      ..z = z
      ..onGround = onGround;
    if (yaw != null) player.yaw = yaw;
    if (pitch != null) player.pitch = pitch;
    _emitPosition(player);
  }

  void _emitPosition(PlaySession player) {
    if (!_endpoint.wants(ProtocolPrimitive.position)) return;
    _endpoint._emit(ProtocolPrimitive.position, player.toFields());
  }

  bool _finite(double value) => value.isFinite;

  Uint8List _disconnect(String text) => encodePacket(0x00, encodeString(jsonEncode({'text': text})));

  /// Closes after the current socket callback returns, so cancelling the
  /// subscription cannot deadlock the read that triggered it. [farewell] is
  /// flushed before the socket is closed.
  Future<void> close(ProtocolCloseReason _, {Uint8List? farewell}) {
    _closed = true;
    return _shutdown ??= _shutdownNow(farewell);
  }

  Future<void> _shutdownNow(Uint8List? farewell) async {
    _keepAliveTimer?.cancel();
    final player = session;
    if (player != null && _phase == _Phase.play) {
      _endpoint._emit(ProtocolPrimitive.closed, {'entityId': player.entityId, 'name': player.name, 'uuid': player.uuid});
    }
    await Future<void>.delayed(Duration.zero);
    if (farewell != null) {
      _socket.add(farewell);
      try {
        await _socket.flush().timeout(const Duration(milliseconds: 500));
      } on Object {
        // The peer may already be gone, or the flush outlived its budget.
      }
    }
    // destroy() returns immediately. Waiting for the socket subscription to
    // cancel can stall on Windows after the peer has already finished.
    _socket.destroy();
    unawaited(_subscription.cancel().then((_) {}, onError: (_, _) {}));
    if (!done.isCompleted) done.complete();
  }
}
