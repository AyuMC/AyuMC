import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'buffer.dart';
import 'chunk_stream.dart';
import 'compression.dart';
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
    this.visibility = const ViewDistanceVisibility(),
    this.entityUpdateInterval = Duration.zero,
    this.columns,
    this.onTick,
    this.terrainChunks = ViewDistanceVisibility.defaultServerChunks,
    this.chunkSendSliceBytes = 256 * 1024,
    this.chunkSendIntervalMillis = 50,
    this.chunkGlobalSendBytes = 2 * 1024 * 1024,
    this.perPlayerPendingChunks = 512,
    this.perPlayerQueuedBytes = 8 * 1024 * 1024,
    this.compressionThreshold = -1,
    this.onColumnDelivered,
    this.spawnFeetX = PlaySession.spawnX,
    this.spawnFeetY = PlaySession.spawnY,
    this.spawnFeetZ = PlaySession.spawnZ,
    this.spawnBlockX = 8,
    this.spawnBlockY = 15,
    this.spawnBlockZ = 8,
    this.levelType = 'flat',
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

  /// Who receives entity packets. The default is [ViewDistanceVisibility].
  /// Replaced, not mutated, when the server view cap changes at runtime.
  PlayerVisibility visibility;

  /// Optional column source. When null, join still sends the prebuilt pad.
  final ChunkColumnSource? columns;

  /// Called on the network tick after entity flush and before chunk slices.
  void Function()? onTick;

  /// Terrain radius when [visibility] is not [ViewDistanceVisibility].
  int terrainChunks;

  /// Bytes handed to one socket per tick for column packets. Live-adjustable.
  int chunkSendSliceBytes;

  /// Interval of the dedicated chunk delivery tick. Live-adjustable.
  int chunkSendIntervalMillis;

  /// Bytes per chunk tick shared by every connection. Live-adjustable.
  int chunkGlobalSendBytes;

  /// Most resident-but-unsent columns one player may hold. Live-adjustable.
  int perPlayerPendingChunks;

  /// Most bytes of resident-but-unsent column packets one player may hold.
  int perPlayerQueuedBytes;

  /// Protocol-47 compression threshold for connections that log in from now
  /// on. `-1` disables compression. Live-adjustable, but the protocol has no
  /// in-play renegotiation, so already-connected clients keep the threshold
  /// they negotiated during login.
  int compressionThreshold;

  /// Delivery scale applied under engine pressure (1.0 normal).
  double chunkSendPressureScale = 1;

  /// Sink for the resident-to-socket wait of each delivered column. The core
  /// points this at the pipeline histogram; it is null in the test harnesses
  /// that do not care.
  void Function(int micros)? onColumnDelivered;

  /// Bytes actually handed to sockets for column packets since start.
  int chunkBytes = 0;
  int chunkDeliveries = 0;
  int chunkUnloads = 0;
  int chunkQueueDepth = 0;
  int chunkQueuedBytes = 0;

  /// Columns cancelled after being queued for a player but before delivery.
  int chunkStaleDrops = 0;

  /// Compression counters. Raw bytes are what the packet would have cost
  /// uncompressed; wire bytes are what the socket received.
  int compressionFrames = 0;
  int compressionRawBytes = 0;
  int compressionWireBytes = 0;

  /// Connections in login order, used to rotate who is served first.
  int _sendRotation = 0;

  final double spawnFeetX;
  final double spawnFeetY;
  final double spawnFeetZ;
  final int spawnBlockX;
  final int spawnBlockY;
  final int spawnBlockZ;
  final String levelType;

  /// How often the latest accepted pose is written to viewers.
  ///
  /// [Duration.zero] sends on the packet that changed the pose. A positive
  /// interval keeps one timer for the whole endpoint and forwards only the
  /// newest pose. Protocol 47 clients interpolate each entity packet over
  /// three ticks, so an update on every inbound packet restarts that
  /// interpolation before it finishes.
  final Duration entityUpdateInterval;

  /// Client position, look, and ground packets that passed validation.
  int acceptedMovementPackets = 0;

  /// Movement and presence packets encoded once, then shared by every viewer.
  int replicationEncodes = 0;

  /// Socket writes of those packets. One encode can produce many deliveries.
  int replicationDeliveries = 0;

  /// Bytes handed to sockets for [replicationDeliveries]. Join terrain is not included.
  int replicationBytes = 0;

  int entitySpawns = 0;
  int entityDestroys = 0;

  /// Largest number of Minecraft frames handled in one socket read.
  int maxFramesPerRead = 0;

  /// Gaps between accepted movement packets, in microseconds.
  int inboundGapCount = 0;
  int inboundGapSumMicros = 0;
  int inboundGapMaxMicros = 0;

  /// Longest wait from the first unsent pose change to the entity packet.
  int replicationDelayMaxMicros = 0;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<PlaySession, _Connection> _bySession = {};
  final ChunkIndex<PlaySession> _chunks = ChunkIndex<PlaySession>();
  final Set<_Connection> _dirty = {};
  Timer? _flushTimer;
  Timer? _chunkTimer;
  int? _lastInboundMicros;

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
    columns?.addReadyListener(_onColumnReady);
    _armNetworkTick();
    _armChunkTick();
  }

  /// Sends every pose that pacing is still holding. Tests use this instead of
  /// waiting for the timer. A suppressed update does not move the baseline
  /// until this runs.
  void flushEntityReplication() {
    final pending = List<_Connection>.of(_dirty);
    _dirty.clear();
    for (final connection in pending) {
      connection._flushSubject();
      connection._flushOwnView();
    }
  }

  Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _chunkTimer?.cancel();
    _chunkTimer = null;
    columns?.removeReadyListener(_onColumnReady);
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
      _dirty.remove(connection);
      final session = connection.session;
      if (session != null) {
        _bySession.remove(session);
        _chunks.remove(session);
      }
      _online--;
    });
  }

  void _emit(String id, Map<String, Object?> data) =>
      onPrimitive?.call(id, data);

  void _noteInbound() {
    final now = _clock.elapsedMicroseconds;
    final previous = _lastInboundMicros;
    _lastInboundMicros = now;
    if (previous == null) return;
    final gap = now - previous;
    inboundGapCount++;
    inboundGapSumMicros += gap;
    if (gap > inboundGapMaxMicros) inboundGapMaxMicros = gap;
  }

  void _noteDelay(int? sinceMicros) {
    if (sinceMicros == null) return;
    final delay = _clock.elapsedMicroseconds - sinceMicros;
    if (delay > replicationDelayMaxMicros) replicationDelayMaxMicros = delay;
  }

  void _track(PlaySession session) {
    _chunks.move(session, chunkCoord(session.x), chunkCoord(session.z));
  }

  void _armFlush() {
    _armNetworkTick();
  }

  void _armNetworkTick() {
    if (_flushTimer != null) return;
    final interval = entityUpdateInterval > Duration.zero
        ? entityUpdateInterval
        : (columns != null || onTick != null
              ? const Duration(milliseconds: 50)
              : Duration.zero);
    if (interval <= Duration.zero) return;
    _flushTimer = Timer.periodic(interval, (_) {
      if (entityUpdateInterval > Duration.zero) {
        flushEntityReplication();
      }
      onTick?.call();
    });
  }

  /// Chunk delivery runs on its own timer so the delivery interval is a real,
  /// separately tunable knob. It never flushes a socket.
  void _armChunkTick() {
    if (columns == null && onTick == null) return;
    final millis = chunkSendIntervalMillis < 5 ? 5 : chunkSendIntervalMillis;
    if (_chunkTimer != null &&
        _chunkIntervalMillis == millis) {
      return;
    }
    _chunkTimer?.cancel();
    _chunkIntervalMillis = millis;
    _chunkTimer = Timer.periodic(
      Duration(milliseconds: millis),
      (_) => _flushChunkStreams(),
    );
  }

  int _chunkIntervalMillis = 50;

  /// Applies a chunk delivery interval change and restarts the timer.
  void setChunkSendInterval(int millis) {
    chunkSendIntervalMillis = millis < 5 ? 5 : millis;
    _armChunkTick();
  }

  void _onColumnReady(int chunkX, int chunkZ) {
    for (final connection in _connections) {
      connection.terrain?.columnReady(chunkX, chunkZ);
      connection._finishJoinIfPossible();
    }
  }

  /// Hands a bounded number of bytes to each connection in turn.
  ///
  /// Two limits apply. The global budget caps what every connection together
  /// may send in one tick, so a player joining with a full view cannot drain
  /// the engine. The per-player slice caps one connection. Both are byte
  /// buckets, not a socket flush; the OS delivers at its own pace and a slow
  /// client's pending columns stay bounded by [perPlayerPendingChunks].
  void _flushChunkStreams() {
    final size = _connections.length;
    if (size == 0) {
      chunkQueueDepth = 0;
      chunkQueuedBytes = 0;
      return;
    }
    final scale = chunkSendPressureScale;
    var remaining = _scaled(chunkGlobalSendBytes, scale);
    var depth = 0;
    var queuedBytes = 0;
    var stale = 0;
    final list = _connections.toList(growable: false);
    final start = _sendRotation++ % size;
    for (var i = 0; i < size; i++) {
      final connection = list[(start + i) % size];
      final terrain = connection.terrain;
      if (terrain == null || connection._closed) continue;
      terrain.maxPendingChunks = perPlayerPendingChunks;
      terrain.maxQueuedBytes = perPlayerQueuedBytes;
      if (remaining > 0) {
        final slice = _scaled(chunkSendSliceBytes, scale);
        final budget = slice < remaining ? slice : remaining;
        remaining -= terrain.sendSlice(budget);
      }
      depth += terrain.queueDepth;
      queuedBytes += terrain.queuedBytes;
      final total = terrain.unsentDrops;
      stale += total - connection._countedStaleDrops;
      connection._countedStaleDrops = total;
    }
    chunkQueueDepth = depth;
    chunkQueuedBytes = queuedBytes;
    chunkStaleDrops += stale;
  }

  int _scaled(int bytes, double scale) {
    final scaled = (bytes * scale).round();
    return scaled < 1 ? 1 : scaled;
  }

  int _terrainRadius(PlaySession session) {
    if (visibility is ViewDistanceVisibility) {
      return (visibility as ViewDistanceVisibility).chunksFor(session);
    }
    return viewSquareRadius(
      serverChunks: terrainChunks,
      clientViewChunks: session.clientViewChunks,
    );
  }

  /// Effective view radius for one live session: the smaller of the server cap
  /// and the client's requested distance.
  int effectiveViewRadius(PlaySession session) => _terrainRadius(session);

  /// Server-side view cap currently in force.
  int get serverViewChunks => visibility is ViewDistanceVisibility
      ? (visibility as ViewDistanceVisibility).effectiveServerChunks
      : terrainChunks.clamp(
          ViewDistanceVisibility.minServerChunks,
          ViewDistanceVisibility.maxServerChunks,
        );

  /// Live view-distance change (requirement: no restart).
  ///
  /// Replaces the visibility description and reconciles every connected
  /// client: a smaller radius cancels obsolete work, releases tickets and
  /// unloads columns the client no longer needs; a larger radius requests the
  /// newly required columns. Resident columns are never regenerated or
  /// reloaded because of a view change.
  void updateViewDistance(int chunks) {
    final clamped = chunks.clamp(
      ViewDistanceVisibility.minServerChunks,
      ViewDistanceVisibility.maxServerChunks,
    );
    terrainChunks = clamped;
    final current = visibility;
    if (current is ViewDistanceVisibility) {
      visibility = current.withServerChunks(clamped);
    }
    for (final connection in _connections) {
      connection._refreshTerrain();
    }
    if (entityUpdateInterval > Duration.zero) {
      flushEntityReplication();
    } else {
      for (final connection in List.of(_connections)) {
        connection._flushSubject();
        connection._flushOwnView();
      }
    }
  }

  /// Diagnostics for the manager: one row per connected session with the view
  /// settings actually in force.
  List<Map<String, Object?>> viewDiagnostics() => [
    for (final connection in _connections)
      if (connection.session != null)
        {
          'name': connection.session!.name,
          'x': connection.session!.x,
          'z': connection.session!.z,
          'chunkX': chunkCoord(connection.session!.x),
          'chunkZ': chunkCoord(connection.session!.z),
          'serverCap': serverViewChunks,
          'clientRequested': connection.session!.clientViewChunks,
          'effectiveRadius': connection._effectiveRadius(),
          'pendingChunks': connection.terrain?.queueDepth ?? 0,
          'pendingBytes': connection.terrain?.queuedBytes ?? 0,
          'heldChunks': connection.terrain?.handedOffCount ?? 0,
          'compressionThreshold': connection.negotiatedThreshold,
        },
  ];

  Map<String, Object?> chunkStats() => {
    'chunkDeliveries': chunkDeliveries,
    'chunkBytes': chunkBytes,
    'chunkUnloads': chunkUnloads,
    'chunkQueueDepth': chunkQueueDepth,
    'chunkQueuedBytes': chunkQueuedBytes,
    'chunkStaleDrops': chunkStaleDrops,
    'compressionFrames': compressionFrames,
    'compressionRawBytes': compressionRawBytes,
    'compressionWireBytes': compressionWireBytes,
    'serverViewChunks': serverViewChunks,
    'sendSliceBytes': chunkSendSliceBytes,
    'sendIntervalMillis': chunkSendIntervalMillis,
    'globalSendBytes': chunkGlobalSendBytes,
  };

  void _markDirty(_Connection connection) {
    connection._dirtySinceMicros ??= _clock.elapsedMicroseconds;
    if (entityUpdateInterval <= Duration.zero) {
      connection._flushSubject();
      connection._flushOwnView();
      return;
    }
    _dirty.add(connection);
    _armFlush();
  }

  /// Other announced connections that might need an entity packet for [subject].
  Iterable<_Connection> _candidates(_Connection subject) {
    final session = subject.session;
    if (session == null) return const [];
    final nearby = visibility is ViewDistanceVisibility
        ? _chunks.around(
            chunkCoord(session.x),
            chunkCoord(session.z),
            (visibility as ViewDistanceVisibility).searchRadiusChunks,
          )
        : null;
    if (nearby == null) {
      return [
        for (final connection in _connections)
          if (!identical(connection, subject) &&
              connection._announced &&
              connection.session != null)
            connection,
      ];
    }
    final found = <_Connection>[];
    for (final other in nearby) {
      if (identical(other, session)) continue;
      final connection = _bySession[other];
      if (connection != null && connection._announced && !connection._closed) {
        found.add(connection);
      }
    }
    return found;
  }

  bool _shouldSee(_Connection viewer, _Connection subject) {
    final viewerSession = viewer.session;
    final subjectSession = subject.session;
    if (viewerSession == null || subjectSession == null) return false;
    return visibility.sees(viewer: viewerSession, subject: subjectSession);
  }

  /// Writes one packet to [targets]. The buffer is shared and not modified.
  ///
  /// When every target negotiated the same compression threshold the frame is
  /// produced once and shared, which is how a chunk packet keeps its encoding
  /// cost independent of the number of recipients.
  void _sendEach(Iterable<_Connection> targets, Uint8List packet) {
    var delivered = 0;
    final shareable = _shareableThreshold(targets);
    if (shareable != null && shareable >= 0) {
      final framed = encodeCompressedFrame(packet, shareable);
      for (final target in targets) {
        if (target._closed) continue;
        if (!target._add(framed)) continue;
        _noteCompression(target, packet.length, framed.length);
        delivered++;
      }
    } else {
      for (final target in targets) {
        if (target._closed) continue;
        if (!target._write(packet)) continue;
        delivered++;
      }
    }
    if (delivered == 0) return;
    replicationEncodes++;
    replicationDeliveries += delivered;
    replicationBytes += packet.length * delivered;
  }

  void _sendOne(_Connection target, Uint8List packet) {
    if (target._closed) return;
    if (!target._write(packet)) return;
    replicationEncodes++;
    replicationDeliveries++;
    replicationBytes += packet.length;
  }

  /// A common threshold when every live target negotiated the same one, or
  /// null when the targets differ or compression is off everywhere.
  int? _shareableThreshold(Iterable<_Connection> targets) {
    int? common = -2;
    for (final target in targets) {
      if (target._closed) continue;
      final threshold = target.negotiatedThreshold ?? -1;
      if (common == -2) {
        common = threshold;
      } else if (common != threshold) {
        return null;
      }
    }
    return common == -2 ? null : common;
  }

  void _noteCompression(_Connection target, int raw, int wire) {
    if ((target.negotiatedThreshold ?? -1) < 0) return;
    compressionFrames++;
    compressionRawBytes += raw;
    compressionWireBytes += wire;
  }

  void _removePlayer(_Connection leaving) {
    if (!leaving._announced) return;
    final player = leaving.session;
    leaving._announced = false;
    _dirty.remove(leaving);
    if (player == null) return;
    _chunks.remove(player);
    final watchers = List<_Connection>.of(leaving._shownTo);
    if (watchers.isNotEmpty) {
      _sendEach(watchers, destroyEntitiesPacket(player.entityId));
      entityDestroys += watchers.length;
    }
    for (final viewer in watchers) {
      viewer._shown.remove(leaving);
    }
    leaving._shownTo.clear();
    for (final subject in List<_Connection>.of(leaving._shown)) {
      subject._shownTo.remove(leaving);
    }
    leaving._shown.clear();
    final everyone = [
      for (final connection in _connections)
        if (!identical(connection, leaving) && connection._announced)
          connection,
    ];
    _sendEach(everyone, playerListRemove(player));
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
    // A peer that disappears mid-write reports the failure on the sink's done
    // future. Handle it here so it cannot escape as an unhandled zone error;
    // the read side closes the connection.
    unawaited(_socket.done.catchError((Object _) => _socket));
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
  int? _dirtySinceMicros;

  /// Viewers that currently have this entity spawned.
  final Set<_Connection> _shownTo = {};

  /// Subjects currently spawned on this client.
  final Set<_Connection> _shown = {};
  Timer? _keepAliveTimer;
  int _keepAliveId = 0;
  bool _awaitingKeepAlive = false;
  DateTime? _keepAliveSentAt;
  ChunkStreamSession? terrain;
  bool _joinRestSent = false;
  int _lastTerrainX = 0;
  int _lastTerrainZ = 0;

  /// Transport compression state for this connection. Not activated until
  /// Login Set Compression has been queued in the correct order.
  final FrameCodec codec = FrameCodec();

  /// Threshold this connection negotiated during login, if any. A later
  /// configuration change does not alter it; protocol 47 has no in-play
  /// renegotiation.
  int? negotiatedThreshold;

  /// Delivery-queue drops already reported to the endpoint counters.
  int _countedStaleDrops = 0;

  int _effectiveRadius() => session == null
      ? 0
      : _endpoint._terrainRadius(session!);

  /// Writes one already-encoded packet through this connection's framing.
  /// Returns false when the connection is closed or the sink is gone.
  bool _write(Uint8List packet) {
    if (_closed) return false;
    return _writeFinal(packet);
  }

  /// Writes ignoring the closed flag, for the farewell that a shutdown still
  /// has to deliver.
  bool _writeFinal(Uint8List packet) {
    final threshold = negotiatedThreshold;
    if (threshold == null || threshold < 0) {
      return _add(packet);
    }
    final framed = encodeCompressedFrame(packet, threshold);
    if (!_add(framed)) return false;
    _endpoint.compressionFrames++;
    _endpoint.compressionRawBytes += packet.length;
    _endpoint.compressionWireBytes += framed.length;
    return true;
  }

  bool _add(Uint8List bytes) {
    try {
      _socket.add(bytes);
      return true;
    } on StateError {
      // The sink is already closed; the read side reports the disconnect.
      return false;
    }
  }

  void _onData(List<int> chunk) {
    _inbound.add(chunk);
    try {
      var framesThisRead = 0;
      while (!_closed) {
        final frame = codec.enabled
            ? _inbound.readCompressedFrame(
                maxFrameBytes: _endpoint.maxFrameBytes,
                maxUncompressedBytes: _endpoint.maxFrameBytes,
              )
            : _inbound.readFrame(maxFrameBytes: _endpoint.maxFrameBytes);
        if (frame == null) break;
        framesThisRead++;
        _handle(PacketBuffer()..add(frame));
      }
      if (framesThisRead > _endpoint.maxFramesPerRead) {
        _endpoint.maxFramesPerRead = framesThisRead;
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
          _write(
            encodePacket(0x00, encodeString(jsonEncode(_endpoint._status))),
          );
        } else if (id == 0x01) {
          _write(encodePacket(0x01, encodeLong(packet.readLong())));
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
      x: _endpoint.spawnFeetX,
      y: _endpoint.spawnFeetY,
      z: _endpoint.spawnFeetZ,
    );
    final player = session!;
    _endpoint._bySession[player] = this;
    final threshold = _endpoint.compressionThreshold;
    if (threshold >= 0) {
      // Set Compression must precede Login Success, and must itself use the
      // pre-compression framing.
      _socket.add(setCompressionPacket(threshold));
      codec.activate(threshold);
      negotiatedThreshold = threshold;
    }
    _write(
      encodePacket(0x02, [...encodeString(uuid), ...encodeString(name)]),
    );
    _phase = _Phase.play;
    _keepAliveTimer = Timer.periodic(_endpoint.keepAliveInterval, _onKeepAlive);
    _write(
      encodePacket(0x01, [
        ...encodeInt(player.entityId),
        0, // survival
        0, // overworld
        1, // easy
        _endpoint.maxPlayers < 1
            ? 1
            : (_endpoint.maxPlayers > 255 ? 255 : _endpoint.maxPlayers),
        ...encodeString(_endpoint.levelType),
        0, // reduced debug info
      ]),
    );
    _write(
      encodePacket(
        0x05,
        encodeBlockPosition(
          _endpoint.spawnBlockX,
          _endpoint.spawnBlockY,
          _endpoint.spawnBlockZ,
        ),
      ),
    );
    _write(
      encodePacket(0x39, [0, ...encodeFloat(0.05), ...encodeFloat(0.1)]),
    );
    if (_endpoint.columns == null) {
      _write(_endpoint._spawnChunk);
      _sendJoinRest();
      return;
    }
    _attachTerrain();
    _finishJoinIfPossible();
  }

  void _attachTerrain() {
    final source = _endpoint.columns;
    if (source == null || session == null) return;
    terrain = ChunkStreamSession(
      holder: this,
      source: source,
      write: (packet, {required bool unload}) {
        _write(packet);
        if (unload) {
          _endpoint.chunkUnloads++;
        } else {
          _endpoint.chunkDeliveries++;
          _endpoint.chunkBytes += packet.length;
        }
      },
      isFlushPending: () => false,
      beginFlush: () {},
      onDelivery: _endpoint.onColumnDelivered,
    );
    _refreshTerrain(prefetch: true);
  }

  void _refreshTerrain({bool prefetch = true}) {
    final player = session;
    final stream = terrain;
    if (player == null || stream == null) return;
    _lastTerrainX = chunkCoord(player.x);
    _lastTerrainZ = chunkCoord(player.z);
    stream.updateView(
      chunkX: _lastTerrainX,
      chunkZ: _lastTerrainZ,
      radius: _endpoint._terrainRadius(player),
      prefetch: prefetch,
    );
  }

  void _finishJoinIfPossible() {
    if (_joinRestSent || _closed) return;
    final player = session;
    if (player == null) return;
    if (_endpoint.columns == null) return;
    final stream = terrain;
    if (stream == null || !stream.standingReady) return;
    final packet = _endpoint.columns!.encoded(stream.centerX, stream.centerZ);
    if (packet == null) return;
    _write(packet);
    stream.markHandedOff(stream.centerX, stream.centerZ);
    _endpoint.chunkDeliveries++;
    _endpoint.chunkBytes += packet.length;
    _sendJoinRest();
  }

  void _sendJoinRest() {
    if (_joinRestSent) return;
    final player = session;
    if (player == null) return;
    _joinRestSent = true;
    _write(
      encodePacket(0x08, [
        ...encodeDouble(player.x),
        ...encodeDouble(player.y),
        ...encodeDouble(player.z),
        ...encodeFloat(0),
        ...encodeFloat(0),
        0,
      ]),
    );
    _write(encodePacket(0x03, [...encodeLong(0), ...encodeLong(6000)]));
    _write(
      encodePacket(0x06, [
        ...encodeFloat(20),
        ...encodeVarInt(20),
        ...encodeFloat(5),
      ]),
    );
    _announce();
    if (_closed) return;
    _endpoint._emit(ProtocolPrimitive.playJoined, player.toFields());
    terrain?.sendSlice(_endpoint.chunkSendSliceBytes);
  }

  /// Tab-list entries are global. The entity itself is spawned only for
  /// sessions inside the visibility range, and the list packet still precedes
  /// that spawn.
  void _announce() {
    final player = session!;
    _endpoint._track(player);
    _sent = QuantizedPose.of(player);
    final add = playerListAdd(player);
    _write(add);
    final others = [
      for (final connection in _endpoint._connections)
        if (!identical(connection, this) &&
            connection._announced &&
            connection.session != null)
          connection,
    ];
    _announced = true;
    if (others.isNotEmpty) {
      _endpoint._sendEach(others, add);
      for (final other in others) {
        _endpoint._sendOne(this, playerListAdd(other.session!));
      }
    }
    _flushSubject();
    _flushOwnView();
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
    _write(encodePacket(0x00, encodeVarInt(_keepAliveId)));
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
        if (packet.length < 1) {
          throw const PacketFormatException('truncated client settings');
        }
        player.clientViewChunks = packet.readUnsignedByte();
        _endpoint._markDirty(this);
        _refreshTerrain();
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
    final previousX = chunkCoord(player.x);
    final previousZ = chunkCoord(player.z);
    player
      ..x = x
      ..y = y
      ..z = z
      ..onGround = onGround;
    if (yaw != null) player.yaw = yaw;
    if (pitch != null) player.pitch = pitch;
    _endpoint.acceptedMovementPackets++;
    _endpoint._noteInbound();
    _endpoint._track(player);
    if (chunkCoord(player.x) != previousX || chunkCoord(player.z) != previousZ) {
      _refreshTerrain();
    }
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
    _endpoint._noteInbound();
    _replicate();
    _emitPosition(player);
  }

  void _replicate() {
    if (session == null || !_announced) return;
    _endpoint._markDirty(this);
  }

  /// Publishes this session to whoever should currently see it.
  ///
  /// [_sent] moves only after a delta is handed to the viewers who already
  /// have the entity, or when nobody still holds the previous pose. A viewer
  /// who just entered range gets a spawn at the new pose, not a delta from a
  /// baseline they never received.
  void _flushSubject() {
    final player = session;
    if (player == null || !_announced) return;
    final next = QuantizedPose.of(player);
    final previous = _sent ?? next;
    final want = {
      for (final viewer in _endpoint._candidates(this))
        if (_endpoint._shouldSee(viewer, this)) viewer,
    };
    final leaving = [
      for (final viewer in _shownTo)
        if (!want.contains(viewer)) viewer,
    ];
    if (leaving.isNotEmpty) {
      _endpoint._sendEach(leaving, destroyEntitiesPacket(player.entityId));
      _endpoint.entityDestroys += leaving.length;
      for (final viewer in leaving) {
        _shownTo.remove(viewer);
        viewer._shown.remove(this);
      }
    }
    final staying = [
      for (final viewer in _shownTo)
        if (want.contains(viewer)) viewer,
    ];
    final changed = !next.sameAs(previous);
    if (changed && staying.isNotEmpty) {
      _sendDelta(previous, next, staying);
      _sent = next;
      _endpoint._noteDelay(_dirtySinceMicros);
      _dirtySinceMicros = null;
    } else if (changed && staying.isEmpty) {
      _sent = next;
    }
    final entering = [
      for (final viewer in want)
        if (!_shownTo.contains(viewer)) viewer,
    ];
    if (entering.isEmpty) return;
    final pose = _sent ?? next;
    final spawn = spawnPlayer(player, pose);
    final head = entityHeadLookPacket(player.entityId, pose.yaw);
    for (final viewer in entering) {
      if (viewer._closed) continue;
      viewer._write(spawn);
      viewer._write(head);
      _shownTo.add(viewer);
      viewer._shown.add(this);
      _endpoint.entitySpawns++;
    }
    _endpoint.replicationEncodes += 2;
    _endpoint.replicationDeliveries += entering.length * 2;
    _endpoint.replicationBytes +=
        (spawn.length + head.length) * entering.length;
    _sent = pose;
  }

  /// Spawns or removes other entities on this client after our bubble moves.
  void _flushOwnView() {
    final player = session;
    if (player == null || !_announced) return;
    for (final subject in _endpoint._candidates(this)) {
      subject._flushSubject();
    }
  }

  void _sendDelta(
    QuantizedPose previous,
    QuantizedPose next,
    List<_Connection> staying,
  ) {
    final player = session!;
    if (next.flags != previous.flags) {
      _endpoint._sendEach(
        staying,
        entityMetadataPacket(entityId: player.entityId, flags: next.flags),
      );
    }
    final moved =
        next.x != previous.x || next.y != previous.y || next.z != previous.z;
    final turned = next.yaw != previous.yaw || next.pitch != previous.pitch;
    final groundChanged = next.onGround != previous.onGround;
    if (!moved && !turned && !groundChanged) return;
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
    _endpoint._sendEach(staying, packet);
    if (next.yaw != previous.yaw) {
      _endpoint._sendEach(
        staying,
        entityHeadLookPacket(player.entityId, next.yaw),
      );
    }
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
    terrain?.close();
    terrain = null;
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
      _writeFinal(farewell);
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
