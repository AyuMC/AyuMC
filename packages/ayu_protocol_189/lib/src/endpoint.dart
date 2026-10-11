import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'buffer.dart';
import 'entity_packets.dart';
import 'flat_chunk.dart';
import 'offline_uuid.dart';
import 'play_session.dart';
import 'primitives.dart';
import 'visibility.dart';

/// Why a connection was closed. Useful in tests and logs.
enum ProtocolCloseReason {
  completed,
  malformed,
  unsupportedState,
  remoteClosed,
  timedOut,
}

typedef PrimitiveListener = void Function(String id, Map<String, Object?> data);
typedef PrimitiveInterest = bool Function(String id);

/// Minecraft 1.8.9 connections.
///
/// Offline mode sends Login Success and the minimum play-state packets for
/// a client to leave the "downloading terrain" screen onto a single stone
/// pad, then tells other play sessions about that player. Online mode is
/// not implemented: with [offlineMode] false, login start is refused. No
/// public gameplay event is defined here.
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
    this.visibility = const AllSessionsVisible(),
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

  /// Who receives entity packets. The default is every other play session.
  final PlayerVisibility visibility;

  /// Client position, look, and ground packets that passed validation.
  int acceptedMovementPackets = 0;

  /// Movement and presence packets encoded once, then shared by every viewer.
  int replicationEncodes = 0;

  /// Socket writes of those packets. One encode can produce many deliveries.
  int replicationDeliveries = 0;

  /// Bytes handed to sockets for [replicationDeliveries]. Join terrain is not included.
  int replicationBytes = 0;

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

  bool wants(String id) =>
      onPrimitive != null && (interestedIn?.call(id) ?? true);

  Future<void> bind({InternetAddress? address, int port = 25565}) async {
    if (_server != null) throw StateError('endpoint already bound');
    _server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
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

  void _emit(String id, Map<String, Object?> data) =>
      onPrimitive?.call(id, data);

  bool _hasViewer(PlaySession subject) {
    for (final connection in _connections) {
      if (!connection._announced || connection._closed) continue;
      final viewer = connection.session;
      if (viewer != null && visibility.sees(viewer: viewer, subject: subject))
        return true;
    }
    return false;
  }

  /// Writes one already-encoded packet to every current viewer of [subject].
  /// The byte buffer is not copied per viewer and is not modified afterwards.
  void _sendShared(PlaySession subject, Uint8List packet) {
    var delivered = 0;
    for (final connection in _connections) {
      if (!connection._announced || connection._closed) continue;
      final viewer = connection.session;
      if (viewer == null || !visibility.sees(viewer: viewer, subject: subject))
        continue;
      connection._socket.add(packet);
      delivered++;
    }
    if (delivered == 0) return;
    replicationEncodes++;
    replicationDeliveries += delivered;
    replicationBytes += packet.length * delivered;
  }

  void _sendOne(_Connection target, Uint8List packet) {
    if (target._closed) return;
    target._socket.add(packet);
    replicationEncodes++;
    replicationDeliveries++;
    replicationBytes += packet.length;
  }

  void _removePlayer(_Connection leaving) {
    if (!leaving._announced) return;
    final player = leaving.session;
    leaving._announced = false;
    if (player == null) return;
    _sendShared(player, destroyEntitiesPacket(player.entityId));
    _sendShared(player, playerListRemove(player));
  }

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
    _subscription = _socket.listen(
      _onData,
      onError: (_) => close(ProtocolCloseReason.remoteClosed),
      onDone: () => close(ProtocolCloseReason.remoteClosed),
    );
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
  QuantizedPose? _sent;
  bool _announced = false;
  Timer? _keepAliveTimer;
  int _keepAliveId = 0;
  bool _awaitingKeepAlive = false;
  DateTime? _keepAliveSentAt;

  void _onData(List<int> chunk) {
    _inbound.add(chunk);
    try {
      while (!_closed) {
        final frame = _inbound.readFrame(
          maxFrameBytes: _endpoint.maxFrameBytes,
        );
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
          _socket.add(
            encodePacket(0x00, encodeString(jsonEncode(_endpoint._status))),
          );
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
          close(
            ProtocolCloseReason.malformed,
            farewell: _disconnect('invalid name'),
          );
          return;
        }
        _endpoint._emit(ProtocolPrimitive.login, {
          'name': name,
          'protocol': _endpoint.protocolVersion,
        });
        if (!_endpoint.offlineMode) {
          close(
            ProtocolCloseReason.unsupportedState,
            farewell: _disconnect('online authentication is not implemented'),
          );
          return;
        }
        _enterPlay(name);
      case _Phase.play:
        _handlePlay(id, packet);
    }
  }

  void _enterPlay(String name) {
    final uuid = offlinePlayerUuid(name);
    final uuidBytes = offlinePlayerUuidBytes(name);
    session = PlaySession(
      entityId: _endpoint._nextEntityId++,
      name: name,
      uuid: uuid,
      uuidBytes: uuidBytes,
      x: PlaySession.spawnX,
      y: PlaySession.spawnY,
      z: PlaySession.spawnZ,
    );
    final player = session!;
    _socket.add(
      encodePacket(0x02, [...encodeString(uuid), ...encodeString(name)]),
    );
    _phase = _Phase.play;
    _socket.add(
      encodePacket(0x01, [
        ...encodeInt(player.entityId),
        0, // survival
        0, // overworld
        1, // easy
        _endpoint.maxPlayers < 1
            ? 1
            : (_endpoint.maxPlayers > 255 ? 255 : _endpoint.maxPlayers),
        ...encodeString('flat'),
        0, // reduced debug info
      ]),
    );
    _socket.add(encodePacket(0x05, encodeBlockPosition(8, 15, 8)));
    _socket.add(
      encodePacket(0x39, [0, ...encodeFloat(0.05), ...encodeFloat(0.1)]),
    );
    _socket.add(
      encodePacket(0x08, [
        ...encodeDouble(player.x),
        ...encodeDouble(player.y),
        ...encodeDouble(player.z),
        ...encodeFloat(0),
        ...encodeFloat(0),
        0,
      ]),
    );
    _socket.add(_endpoint._spawnChunk);
    _socket.add(encodePacket(0x03, [...encodeLong(0), ...encodeLong(6000)]));
    _socket.add(
      encodePacket(0x06, [
        ...encodeFloat(20),
        ...encodeVarInt(20),
        ...encodeFloat(5),
      ]),
    );
    _announce();
    if (_closed) return;
    _endpoint._emit(ProtocolPrimitive.playJoined, player.toFields());
    _keepAliveTimer = Timer.periodic(_endpoint.keepAliveInterval, _onKeepAlive);
  }

  /// Player-list entries go out before the matching spawn. The bytes for this
  /// player are encoded once and written to every viewer already in play.
  void _announce() {
    final player = session!;
    _sent = QuantizedPose.of(player);
    final add = playerListAdd(player);
    _socket.add(add);
    final others = [
      for (final connection in _endpoint._connections)
        if (!identical(connection, this) &&
            connection._announced &&
            connection.session != null)
          connection,
    ];
    _announced = true;
    final pose = _sent!;
    _endpoint._sendShared(player, add);
    _endpoint._sendShared(player, spawnPlayer(player, pose));
    _endpoint._sendShared(
      player,
      entityHeadLookPacket(player.entityId, pose.yaw),
    );
    for (final other in others) {
      final theirSession = other.session!;
      final theirPose = other._sent ?? QuantizedPose.of(theirSession);
      other._sent = theirPose;
      _endpoint._sendOne(this, playerListAdd(theirSession));
      _endpoint._sendOne(this, spawnPlayer(theirSession, theirPose));
      _endpoint._sendOne(
        this,
        entityHeadLookPacket(theirSession.entityId, theirPose.yaw),
      );
    }
  }

  void _onKeepAlive(Timer timer) {
    if (_closed || _phase != _Phase.play) return;
    if (_awaitingKeepAlive &&
        _keepAliveSentAt != null &&
        DateTime.now().difference(_keepAliveSentAt!) >
            _endpoint.keepAliveTimeout) {
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
        _endpoint.acceptedMovementPackets++;
        _replicate();
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
        _applyLook(
          player,
          packet.readFloat(),
          packet.readFloat(),
          packet.readBool(),
        );
        return;
      case 0x0B:
        final entityId = packet.readVarInt();
        final action = packet.readVarInt();
        packet.readVarInt();
        if (entityId != player.entityId) return;
        switch (action) {
          case 0:
            player.sneaking = true;
          case 1:
            player.sneaking = false;
          case 3:
            player.sprinting = true;
          case 4:
            player.sprinting = false;
          default:
            return;
        }
        _replicate();
        return;
      case 0x15:
        packet.readString();
        if (packet.length < 4)
          throw const PacketFormatException('truncated client settings');
        return;
      default:
        return;
    }
  }

  void _applyPosition(
    PlaySession player,
    double x,
    double y,
    double z, {
    double? yaw,
    double? pitch,
    required bool onGround,
  }) {
    if (!_finite(x) ||
        !_finite(y) ||
        !_finite(z) ||
        x.abs() > 3e7 ||
        z.abs() > 3e7 ||
        y < -64 ||
        y > 4096) {
      return;
    }
    if (yaw != null && (!_finite(yaw) || pitch == null || !_finite(pitch))) {
      return;
    }
    player
      ..x = x
      ..y = y
      ..z = z
      ..onGround = onGround;
    if (yaw != null) player.yaw = yaw;
    if (pitch != null) player.pitch = pitch;
    _endpoint.acceptedMovementPackets++;
    _replicate();
    _emitPosition(player);
  }

  void _applyLook(PlaySession player, double yaw, double pitch, bool onGround) {
    if (!_finite(yaw) || !_finite(pitch)) return;
    player
      ..yaw = yaw
      ..pitch = pitch
      ..onGround = onGround;
    _endpoint.acceptedMovementPackets++;
    _replicate();
    _emitPosition(player);
  }

  /// Sends the smallest protocol-47 update that matches the change since
  /// [_sent], then advances that snapshot. A brand-new viewer is spawned from
  /// the snapshot, so it does not replay older deltas.
  void _replicate() {
    final player = session;
    if (player == null || !_announced) return;
    final next = QuantizedPose.of(player);
    final previous = _sent;
    if (previous == null || next.sameAs(previous)) {
      _sent = next;
      return;
    }
    final flagsChanged = next.flags != previous.flags;
    final moved =
        next.x != previous.x || next.y != previous.y || next.z != previous.z;
    final turned = next.yaw != previous.yaw || next.pitch != previous.pitch;
    final groundChanged = next.onGround != previous.onGround;
    if (!_endpoint._hasViewer(player)) {
      _sent = next;
      return;
    }
    if (flagsChanged) {
      _endpoint._sendShared(
        player,
        entityMetadataPacket(entityId: player.entityId, flags: next.flags),
      );
    }
    if (moved || turned || groundChanged) {
      final dx = next.x - previous.x;
      final dy = next.y - previous.y;
      final dz = next.z - previous.z;
      final absolute =
          !relativeDeltaFits(dx) ||
          !relativeDeltaFits(dy) ||
          !relativeDeltaFits(dz);
      final Uint8List packet;
      if (absolute) {
        packet = entityTeleportPacket(player.entityId, next);
      } else if (turned && (moved || groundChanged)) {
        packet = entityLookMovePacket(player.entityId, next, dx, dy, dz);
      } else if (turned) {
        packet = entityLookPacket(player.entityId, next);
      } else {
        packet = entityRelativeMovePacket(player.entityId, next, dx, dy, dz);
      }
      _endpoint._sendShared(player, packet);
      if (next.yaw != previous.yaw) {
        _endpoint._sendShared(
          player,
          entityHeadLookPacket(player.entityId, next.yaw),
        );
      }
    }
    _sent = next;
  }

  void _emitPosition(PlaySession player) {
    if (!_endpoint.wants(ProtocolPrimitive.position)) return;
    _endpoint._emit(ProtocolPrimitive.position, player.toFields());
  }

  bool _finite(double value) => value.isFinite;

  Uint8List _disconnect(String text) =>
      encodePacket(0x00, encodeString(jsonEncode({'text': text})));

  /// Closes after the current socket callback returns, so cancelling the
  /// subscription cannot deadlock the read that triggered it. [farewell] is
  /// flushed before the socket is closed.
  Future<void> close(ProtocolCloseReason _, {Uint8List? farewell}) {
    _closed = true;
    return _shutdown ??= _shutdownNow(farewell);
  }

  Future<void> _shutdownNow(Uint8List? farewell) async {
    _keepAliveTimer?.cancel();
    _endpoint._removePlayer(this);
    final player = session;
    if (player != null && _phase == _Phase.play) {
      _endpoint._emit(ProtocolPrimitive.closed, {
        'entityId': player.entityId,
        'name': player.name,
        'uuid': player.uuid,
      });
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
