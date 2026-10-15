import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_protocol_189/ayu_protocol_189.dart';
import 'package:ayu_world/ayu_world.dart';
import 'package:test/test.dart';

void main() {
  test(
    'standing column is decoded before position, and delivery stays bounded',
    () async {
      final pipeline = ChunkPipeline(
        generator: const FlatStonePadGenerator(),
        seed: 0,
        encoder: _encode,
        config: const ChunkConfig(cacheMiB: 0),
      );
      final source = _Columns(pipeline);
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'chunks',
        keepAliveInterval: const Duration(hours: 1),
        visibility: const ViewDistanceVisibility(serverChunks: 2),
        columns: source,
        onTick: pipeline.tick,
        chunkSendSliceBytes: 1,
      );
      await endpoint.bind(port: 0);
      final client = await _Client.connect(endpoint.port, 'Steve');
      try {
        await _until(
          () => client.burstData >= 0,
          'login did not reach the position packet',
        );
        expect(client.dataBeforePosition, 1);
        expect(client.standing.chunkX, 0);
        expect(client.standing.chunkZ, 0);
        expect(client.standing.primaryBitmask, isNot(0));
        expect(client.burstData, lessThan(25));
        await _until(
          () => client.dataColumns > client.burstData,
          'later slices did not arrive',
        );
        final beforeMove = client.frames.length;
        client.socket.add(
          encodePacket(0x04, [
            ...encodeDouble(328.5),
            ...encodeDouble(16),
            ...encodeDouble(8.5),
            1,
          ]),
        );
        await _until(
          () => endpoint.sessions.single.x == 328.5,
          'the move was not applied',
        );
        await _until(
          () => client
              .chunksAfter(beforeMove)
              .any(
                (column) =>
                    column.primaryBitmask != 0 &&
                    _chebyshev(column.chunkX, column.chunkZ, 20, 0) <= 2,
              ),
          'the new view was not decoded',
        );
        expect(
          client
              .chunksAfter(beforeMove)
              .where(
                (column) => column.primaryBitmask != 0 && column.chunkX == 0,
              ),
          isEmpty,
        );
        pipeline.tick();
        // ignore: avoid_print
        print(
          'stream deliveries=${endpoint.chunkDeliveries} '
          'bytes=${endpoint.chunkBytes} '
          'queue=${endpoint.chunkQueueDepth} '
          'generates=${pipeline.stats.generates} '
          'dedup=${pipeline.stats.dedupHits} '
          'residents=${pipeline.stats.residentKeys}',
        );
      } finally {
        await client.close();
        await endpoint.close();
        await pipeline.close();
      }
    },
  );

  test('terrain standing column is decoded before a safe spawn look', () async {
    final pipeline = ChunkPipeline(
      generator: TerrainGeneratorV1(),
      seed: 42,
      encoder: _encode,
      config: const ChunkConfig(workers: 0),
    );
    final found = await findSafeSpawn(pipeline);
    final source = _Columns(pipeline);
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'terrain',
      keepAliveInterval: const Duration(hours: 1),
      visibility: const ViewDistanceVisibility(serverChunks: 2),
      columns: source,
      onTick: pipeline.tick,
      spawnFeetX: found.spawn.feetX,
      spawnFeetY: found.spawn.feetY,
      spawnFeetZ: found.spawn.feetZ,
      spawnBlockX: found.spawn.blockX,
      spawnBlockY: found.spawn.blockY,
      spawnBlockZ: found.spawn.blockZ,
      levelType: found.spawn.levelType,
    );
    await endpoint.bind(port: 0);
    final client = await _Client.connect(endpoint.port, 'Steve');
    try {
      await _until(
        () => client.burstData >= 0,
        'terrain login did not reach the position packet',
      );
      expect(client.dataBeforePosition, 1);
      expect(client.standing.chunkX, found.chunkX);
      expect(client.standing.chunkZ, found.chunkZ);
      expect(client.standing.primaryBitmask, isNot(0));
      final look = client.frames.firstWhere(
        (frame) => (PacketBuffer()..add(frame)).readVarInt() == 0x08,
      );
      final body = PacketBuffer()..add(look);
      expect(body.readVarInt(), 0x08);
      body.readDouble();
      expect(body.readDouble(), found.spawn.feetY);
    } finally {
      await client.close();
      await endpoint.close();
      await pipeline.close();
    }
  });

  test(
    'play packets are accepted while a chunk read is still pending',
    () async {
      final storage = _HoldStorage();
      final pipeline = ChunkPipeline(
        generator: const FlatStonePadGenerator(),
        seed: 0,
        storage: storage,
        encoder: _encode,
      );
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'chunks',
        keepAliveInterval: const Duration(hours: 1),
        visibility: const ViewDistanceVisibility(serverChunks: 2),
        columns: _Columns(pipeline),
        onTick: pipeline.tick,
      );
      await endpoint.bind(port: 0);
      final client = await _Client.connect(endpoint.port, 'Steve');
      try {
        await _until(
          () => endpoint.sessions.isNotEmpty,
          'session was not created',
        );
        expect(client.burstData, -1);
        client.socket.add(
          encodePacket(0x04, [
            ...encodeDouble(10),
            ...encodeDouble(16),
            ...encodeDouble(12),
            1,
          ]),
        );
        await _until(
          () =>
              endpoint.sessions.single.x == 10 &&
              endpoint.acceptedMovementPackets > 0,
          'position was not applied while the chunk read was pending',
        );
        expect(client.burstData, -1);
        storage.release();
        await _until(
          () => client.burstData >= 0,
          'position packet was not sent',
        );
        expect(client.dataBeforePosition, 1);
        expect(client.standing.chunkX, 0);
        expect(client.standing.chunkZ, 0);
      } finally {
        storage.release();
        await client.close();
        await endpoint.close();
        await pipeline.close();
      }
    },
  );

  test(
    'two clients share generation, and a move is replicated before a gated column',
    () async {
      final storage = _HoldStorage(open: true);
      final pipeline = ChunkPipeline(
        generator: const FlatStonePadGenerator(),
        seed: 0,
        storage: storage,
        encoder: _encode,
      );
      final endpoint = ProtocolEndpoint(
        versionName: 'AyuMC 1.8.9',
        protocolVersion: 47,
        description: 'chunks',
        keepAliveInterval: const Duration(hours: 1),
        visibility: const ViewDistanceVisibility(serverChunks: 2),
        columns: _Columns(pipeline),
        onTick: pipeline.tick,
        chunkSendSliceBytes: 256 * 1024,
      );
      await endpoint.bind(port: 0);
      final steve = await _Client.connect(endpoint.port, 'Steve');
      final alex = await _Client.connect(endpoint.port, 'Alex');
      try {
        await _until(
          () => steve.burstData >= 0 && alex.burstData >= 0,
          'both clients did not enter play',
        );
        await _until(
          () => _referencedSettled(pipeline),
          'chunk work did not settle',
        );
        final generates = pipeline.stats.generates;
        expect(generates, greaterThan(0));
        expect(pipeline.stats.dedupHits, greaterThan(0));
        expect(
          pipeline.residency.records.values
              .where((record) => record.phase == ChunkPhase.resident)
              .length,
          generates,
        );
        storage.open = false;
        final mark = alex.frames.length;
        steve.socket.add(
          encodePacket(0x04, [
            ...encodeDouble(40.5),
            ...encodeDouble(16),
            ...encodeDouble(8.5),
            1,
          ]),
        );
        await _until(
          () => endpoint.sessions.any(
            (session) => session.name == 'Steve' && session.x == 40.5,
          ),
          'Steve did not move',
        );
        await _until(
          () => alex.frames.skip(mark).any(_isTeleport),
          'Alex did not get the entity teleport while the new column was pending',
        );
        expect(steve.chunks().any((column) => column.chunkX == 4), isFalse);
        storage.release();
        await _until(
          () => steve.chunks().any(
            (column) => column.chunkX == 4 && column.primaryBitmask != 0,
          ),
          'the newly required column was not decoded',
        );
      } finally {
        storage.release();
        await steve.close();
        await alex.close();
        await endpoint.close();
        await pipeline.close();
      }
    },
  );

  test('disconnect releases chunk tickets', () async {
    final pipeline = ChunkPipeline(
      generator: const FlatStonePadGenerator(),
      seed: 0,
      encoder: _encode,
      config: const ChunkConfig(cacheMiB: 0),
    );
    final endpoint = ProtocolEndpoint(
      versionName: 'AyuMC 1.8.9',
      protocolVersion: 47,
      description: 'chunks',
      keepAliveInterval: const Duration(hours: 1),
      visibility: const ViewDistanceVisibility(serverChunks: 2),
      columns: _Columns(pipeline),
      onTick: pipeline.tick,
    );
    await endpoint.bind(port: 0);
    final client = await _Client.connect(endpoint.port, 'Steve');
    try {
      await _until(() => client.burstData >= 0, 'client did not enter play');
      await client.close();
      await _until(() => endpoint.sessions.isEmpty, 'session was not removed');
      await pipeline.flushWrites();
      pipeline.tick();
      await _until(
        () => pipeline.residency.records.values.every(
          (record) => record.tickets.isEmpty,
        ),
        'a ticket survived disconnect',
      );
      expect(
        pipeline.residency.records.values.where(
          (record) => record.phase == ChunkPhase.resident,
        ),
        isEmpty,
      );
    } finally {
      await endpoint.close();
      await pipeline.close();
    }
  });
}

Uint8List _encode(int x, int z, ChunkPayload payload) {
  return encodeChunkColumn(
    chunkX: x,
    chunkZ: z,
    primaryBitmask: payload.primaryBitmask,
    sections: payload.sections,
    biomes: payload.biomes,
    skylight: payload.skylight,
  );
}

bool _referencedSettled(ChunkPipeline pipeline) {
  for (final record in pipeline.residency.records.values) {
    if (!record.referenced) continue;
    if (record.phase != ChunkPhase.resident &&
        record.phase != ChunkPhase.failed) {
      return false;
    }
  }
  return pipeline.residency.records.isNotEmpty;
}

int _chebyshev(int ax, int az, int bx, int bz) {
  final dx = ax - bx;
  final dz = az - bz;
  final adx = dx < 0 ? -dx : dx;
  final adz = dz < 0 ? -dz : dz;
  return adx > adz ? adx : adz;
}

bool _isTeleport(Uint8List frame) =>
    (PacketBuffer()..add(frame)).readVarInt() == 0x18;

Future<void> _until(bool Function() condition, String why) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(why);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _handshake() {
  return encodePacket(0x00, [
    ...encodeVarInt(47),
    ...encodeString('localhost'),
    ...encodeUnsignedShort(25565),
    ...encodeVarInt(2),
  ]);
}

final class _Columns implements ChunkColumnSource {
  _Columns(this.pipeline) {
    pipeline.addReadyListener((key) {
      for (final listener in List.of(_listeners)) {
        listener(key.x, key.z);
      }
    });
  }

  final ChunkPipeline pipeline;
  final List<void Function(int chunkX, int chunkZ)> _listeners = [];

  @override
  void acquire(
    Object holder,
    int chunkX,
    int chunkZ, {
    required int band,
    int? priorityRing,
  }) {
    pipeline.addTicket(
      holder,
      ChunkKey(worldId: ChunkKey.overworld, x: chunkX, z: chunkZ),
      TicketReason.values[band.clamp(0, TicketReason.values.length - 1)],
      priorityRing: priorityRing,
    );
  }

  @override
  void release(Object holder, int chunkX, int chunkZ) {
    pipeline.removeTicket(
      holder,
      ChunkKey(worldId: ChunkKey.overworld, x: chunkX, z: chunkZ),
    );
  }

  @override
  void releaseAll(Object holder) => pipeline.releaseAll(holder);

  @override
  Uint8List? encoded(int chunkX, int chunkZ) => pipeline.encoded(
    ChunkKey(worldId: ChunkKey.overworld, x: chunkX, z: chunkZ),
  );

  @override
  void addReadyListener(void Function(int chunkX, int chunkZ) listener) {
    _listeners.add(listener);
  }

  @override
  void removeReadyListener(void Function(int chunkX, int chunkZ) listener) {
    _listeners.remove(listener);
  }
}

final class _HoldStorage implements ChunkStorage {
  _HoldStorage({this.open = false});

  final MemoryChunkStorage inner = MemoryChunkStorage();
  Completer<void>? _parked;
  bool open;

  void release() {
    open = true;
    final parked = _parked;
    _parked = null;
    if (parked != null && !parked.isCompleted) parked.complete();
  }

  @override
  Future<ChunkLookup> lookup(ChunkKey key) async {
    if (!open) {
      _parked ??= Completer<void>();
      await _parked!.future;
    }
    return inner.lookup(key);
  }

  @override
  Future<void> store(
    ChunkKey key,
    ChunkPayload payload, {
    required String generatorId,
    required int generatorVersion,
    required bool regenerable,
    required bool playerModified,
    required bool finalized,
  }) {
    return inner.store(
      key,
      payload,
      generatorId: generatorId,
      generatorVersion: generatorVersion,
      regenerable: regenerable,
      playerModified: playerModified,
      finalized: finalized,
    );
  }

  @override
  Future<void> quarantine(ChunkKey key, List<int> bytes) =>
      inner.quarantine(key, bytes);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}

final class _Client {
  _Client(this.socket);

  final Socket socket;
  final PacketBuffer buffer = PacketBuffer();
  final List<Uint8List> frames = [];
  StreamSubscription<Uint8List>? subscription;
  var burstData = -1;
  var dataBeforePosition = 0;
  DecodedChunkColumn? _standing;

  DecodedChunkColumn get standing => _standing!;

  static Future<_Client> connect(int port, String name) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final client = _Client(socket);
    client.subscription = socket.listen((chunk) {
      client.buffer.add(chunk);
      while (true) {
        final frame = client.buffer.readFrame();
        if (frame == null) break;
        client.frames.add(frame);
        final id = (PacketBuffer()..add(frame)).readVarInt();
        if (id == 0x21) {
          final column = decodeChunkColumn(frame);
          if (column != null &&
              column.primaryBitmask != 0 &&
              client.burstData < 0) {
            client.dataBeforePosition++;
            client._standing ??= column;
          }
        }
        if (id == 0x08 && client.burstData < 0) {
          client.burstData = client.dataColumns;
        }
      }
    });
    socket.add(_handshake());
    socket.add(encodePacket(0x00, encodeString(name)));
    return client;
  }

  int get dataColumns =>
      chunks().where((column) => column.primaryBitmask != 0).length;

  List<DecodedChunkColumn> chunks() => [
    for (final frame in frames)
      if ((PacketBuffer()..add(frame)).readVarInt() == 0x21)
        ?decodeChunkColumn(frame),
  ];

  List<DecodedChunkColumn> chunksAfter(int frameIndex) => [
    for (final frame in frames.skip(frameIndex))
      if ((PacketBuffer()..add(frame)).readVarInt() == 0x21)
        ?decodeChunkColumn(frame),
  ];

  Future<void> close() async {
    await subscription?.cancel();
    socket.destroy();
  }
}
