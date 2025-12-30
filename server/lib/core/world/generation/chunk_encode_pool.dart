import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../logging/server_logger.dart';
import '../map_dimension.dart';
import 'flat_world_chunk_encoder.dart';

/// Multi-threaded chunk encoding pool (isolate-per-core).
///
/// This is a message-based isolate pool (no closure passing), designed for
/// high-throughput chunk encoding with minimal main-isolate CPU usage.
class ChunkEncodePool {
  static const String _tag = 'ChunkEncodePool';
  static final ServerLogger _logger = ServerLogger();

  static final ChunkEncodePool _instance = ChunkEncodePool._internal();
  factory ChunkEncodePool() => _instance;
  ChunkEncodePool._internal();

  final List<_ChunkEncodeWorker> _workers = [];
  int _rr = 0;
  bool _initialized = false;

  Future<void> initialize({int? workerCount}) async {
    if (_initialized) return;

    final cores = Platform.numberOfProcessors;
    final count = (workerCount ?? (cores - 1).clamp(1, 16)).clamp(1, 16);

    for (int i = 0; i < count; i++) {
      _workers.add(await _ChunkEncodeWorker.spawn(i));
    }

    _initialized = true;
    _logger.info(_tag, 'Initialized with $count workers (cores: $cores)');
  }

  bool get isInitialized => _initialized;

  Future<TransferableTypedData> encodeFlatChunkPacket({
    required MapDimension dimension,
    required int chunkX,
    required int chunkZ,
  }) async {
    if (!_initialized) {
      // Fallback: do it on main isolate (still fast due to template encoding).
      final bytes = FlatWorldChunkEncoder.encodeChunkPacket(
        dimension: dimension,
        chunkX: chunkX,
        chunkZ: chunkZ,
      );
      return TransferableTypedData.fromList([bytes]);
    }

    final worker = _nextWorker();
    return worker.encodeFlatChunkPacket(dimension, chunkX, chunkZ);
  }

  _ChunkEncodeWorker _nextWorker() {
    final w = _workers[_rr];
    _rr = (_rr + 1) % _workers.length;
    return w;
  }

  Future<void> shutdown() async {
    for (final w in _workers) {
      await w.dispose();
    }
    _workers.clear();
    _initialized = false;
  }
}

class _ChunkEncodeWorker {
  final int id;
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;

  _ChunkEncodeWorker._(
    this.id,
    this._isolate,
    this._sendPort,
    this._receivePort,
  );

  static Future<_ChunkEncodeWorker> spawn(int id) async {
    final rp = ReceivePort();
    final isolate = await Isolate.spawn(_entry, rp.sendPort);
    final sp = await rp.first as SendPort;
    return _ChunkEncodeWorker._(id, isolate, sp, rp);
  }

  static void _entry(SendPort mainSendPort) {
    final rp = ReceivePort();
    mainSendPort.send(rp.sendPort);

    rp.listen((message) {
      if (message is List && message.length == 4) {
        final reply = message[0] as SendPort;
        final dimIndex = message[1] as int;
        final chunkX = message[2] as int;
        final chunkZ = message[3] as int;

        try {
          final bytes = FlatWorldChunkEncoder.encodeChunkPacket(
            dimension: MapDimension.values[dimIndex],
            chunkX: chunkX,
            chunkZ: chunkZ,
          );
          reply.send(TransferableTypedData.fromList([bytes]));
        } catch (e) {
          reply.send(e);
        }
      }
    });
  }

  Future<TransferableTypedData> encodeFlatChunkPacket(
    MapDimension dimension,
    int chunkX,
    int chunkZ,
  ) async {
    final replyPort = ReceivePort();
    _sendPort.send([replyPort.sendPort, dimension.index, chunkX, chunkZ]);
    final msg = await replyPort.first;
    replyPort.close();

    if (msg is TransferableTypedData) return msg;
    throw StateError('Chunk encode failed on worker $id: $msg');
  }

  Future<void> dispose() async {
    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
  }
}
