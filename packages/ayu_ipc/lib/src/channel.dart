import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'frame.dart';
import 'protocol.dart';

/// Byte sink with explicit flush so the channel can observe backpressure.
abstract interface class FrameSink {
  void add(List<int> bytes);
  Future<void> flush();
  Future<void> close();
}

/// Adapts a `dart:io` [IOSink] (process stdin, stdout, socket).
final class IoFrameSink implements FrameSink {
  IoFrameSink(this._sink);

  final IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() => _sink.close();
}

typedef RequestHandler =
    FutureOr<Object?> Function(String method, Object? params);
typedef NotificationHandler = void Function(String method, Object? params);
typedef UnhandledErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Why a channel stopped.
enum ChannelCloseKind { eof, protocolError, transportError, closedLocally }

final class ChannelCloseReason {
  const ChannelCloseReason(this.kind, [this.detail]);

  final ChannelCloseKind kind;
  final String? detail;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}

/// Counters useful for diagnostics and tests.
final class ChannelStats {
  int framesIn = 0;
  int framesOut = 0;
  int bytesIn = 0;
  int bytesOut = 0;
  int droppedNotifications = 0;
  int rejectedInbound = 0;
  int lateResponses = 0;
  int unflushedBytes = 0;
}

/// Bidirectional request/response + notification channel over a byte
/// stream. Symmetric: the same class serves the host and the worker.
final class FrameChannel {
  FrameChannel({
    required Stream<List<int>> input,
    required FrameSink output,
    this.options = const ChannelOptions(),
    this.debugName = 'ipc',
  }) : _output = output,
       _decoder = FrameDecoder(maxFrameBytes: options.maxFrameBytes) {
    _subscription = input.listen(
      _onData,
      onError: (Object error, StackTrace _) =>
          _fail(ChannelCloseReason(ChannelCloseKind.transportError, '$error')),
      onDone: () => _fail(const ChannelCloseReason(ChannelCloseKind.eof)),
      cancelOnError: true,
    );
  }

  final ChannelOptions options;
  final String debugName;
  final FrameSink _output;
  final FrameDecoder _decoder;
  final ChannelStats stats = ChannelStats();

  RequestHandler? onRequest;
  NotificationHandler? onNotification;

  /// Receives errors thrown by notification handlers and by late failures
  /// that have no caller to propagate to. Defaults to the current zone.
  UnhandledErrorHandler? onUnhandledError;

  late final StreamSubscription<List<int>> _subscription;
  final Map<int, _Pending> _pending = {};
  final Completer<void> _done = Completer<void>();
  ChannelCloseReason? _closeReason;
  int _nextId = 1;
  int _inFlightInbound = 0;

  /// Frames waiting for the pump. A single pump loop owns the sink because
  /// `IOSink.add` must never overlap a pending `IOSink.flush`.
  List<Uint8List> _outQueue = [];
  bool _pumping = false;
  Completer<void>? _pumpIdle;
  Future<void>? _outputClosed;

  bool get isOpen => _closeReason == null;
  ChannelCloseReason? get closeReason => _closeReason;

  /// Completes (never errors) once the channel stopped for any reason.
  Future<void> get done => _done.future;

  /// Sends a request and waits for the peer's response.
  Future<Object?> request(String method, [Object? params, Duration? timeout]) {
    final reason = _closeReason;
    if (reason != null) {
      throw IpcException.code(IpcErrorCode.closed, 'channel closed ($reason)');
    }
    if (_pending.length >= options.maxPendingRequests) {
      throw IpcException.code(
        IpcErrorCode.tooManyRequests,
        '${options.maxPendingRequests} requests already pending',
      );
    }
    final id = _allocateId();
    final bytes = _encode(FrameKind.request, id, {'m': method, 'p': params});
    final completer = Completer<Object?>();
    final effectiveTimeout = timeout ?? options.defaultRequestTimeout;
    final timer = Timer(effectiveTimeout, () {
      final pending = _pending.remove(id);
      if (pending == null) return;
      pending.completer.completeError(
        IpcException.code(
          IpcErrorCode.timeout,
          '$method did not complete within ${effectiveTimeout.inMilliseconds} ms',
        ),
      );
    });
    _pending[id] = _Pending(completer, timer, method);
    _send(bytes);
    return completer.future;
  }

  /// Sends a one-way notification. Returns `false` if it was dropped because
  /// the channel is closed or the outbound buffer is above its high-water
  /// mark.
  bool notify(String method, [Object? params]) {
    if (_closeReason != null) return false;
    if (stats.unflushedBytes > options.outboundHighWatermarkBytes) {
      stats.droppedNotifications++;
      return false;
    }
    final Uint8List bytes;
    try {
      bytes = _encode(FrameKind.notification, 0, {'m': method, 'p': params});
    } on IpcException {
      stats.droppedNotifications++;
      return false;
    }
    _send(bytes);
    return true;
  }

  /// Closes the channel locally. Already queued frames are flushed first;
  /// pending requests fail with [IpcErrorCode.closed].
  Future<void> close() {
    _fail(const ChannelCloseReason(ChannelCloseKind.closedLocally));
    return _outputClosed!;
  }

  // ---------------------------------------------------------------- inbound

  void _onData(List<int> chunk) {
    stats.bytesIn += chunk.length;
    final List<Frame> frames;
    try {
      frames = _decoder.addChunk(chunk);
    } on FrameFormatException catch (e) {
      _fail(ChannelCloseReason(ChannelCloseKind.protocolError, e.message));
      return;
    }
    for (final frame in frames) {
      stats.framesIn++;
      if (!_dispatch(frame)) return;
    }
  }

  /// Returns `false` when the frame was fatal and the channel is now closed.
  bool _dispatch(Frame frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame.payload));
    } on FormatException catch (e) {
      _fail(
        ChannelCloseReason(
          ChannelCloseKind.protocolError,
          'payload is not JSON: ${e.message}',
        ),
      );
      return false;
    }
    if (decoded is! Map) {
      _fail(
        const ChannelCloseReason(
          ChannelCloseKind.protocolError,
          'payload is not a JSON object',
        ),
      );
      return false;
    }
    final payload = decoded.cast<String, Object?>();
    switch (frame.kind) {
      case FrameKind.request:
        _handleRequest(frame.id, payload);
      case FrameKind.response:
        _handleResponse(frame.id, payload);
      case FrameKind.notification:
        _handleNotification(payload);
    }
    return true;
  }

  void _handleRequest(int id, Map<String, Object?> payload) {
    final method = payload['m'];
    if (method is! String) {
      _respondError(
        id,
        const IpcError(IpcErrorCode.protocol, 'request without method'),
      );
      return;
    }
    if (_inFlightInbound >= options.maxInFlightInbound) {
      stats.rejectedInbound++;
      _respondError(
        id,
        IpcError(
          IpcErrorCode.tooManyRequests,
          '${options.maxInFlightInbound} inbound requests already in flight',
        ),
      );
      return;
    }
    final handler = onRequest;
    if (handler == null) {
      _respondError(
        id,
        IpcError(IpcErrorCode.methodNotFound, 'no handler for $method'),
      );
      return;
    }
    _inFlightInbound++;
    Future.sync(() => handler(method, payload['p']))
        .then(
          (result) {
            _respondOk(id, result);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (error is IpcException) {
              _respondError(id, error.error);
            } else {
              _respondError(
                id,
                IpcError(IpcErrorCode.internal, _truncate('$error')),
              );
            }
          },
        )
        .whenComplete(() => _inFlightInbound--);
  }

  void _handleResponse(int id, Map<String, Object?> payload) {
    final pending = _pending.remove(id);
    if (pending == null) {
      stats.lateResponses++;
      return;
    }
    pending.timer.cancel();
    if (payload['ok'] == true) {
      pending.completer.complete(payload['r']);
    } else {
      pending.completer.completeError(
        IpcException(IpcError.fromJson(payload['e'])),
      );
    }
  }

  void _handleNotification(Map<String, Object?> payload) {
    final method = payload['m'];
    if (method is! String) {
      _fail(
        const ChannelCloseReason(
          ChannelCloseKind.protocolError,
          'notification without method',
        ),
      );
      return;
    }
    final handler = onNotification;
    if (handler == null) return;
    try {
      handler(method, payload['p']);
    } catch (error, stackTrace) {
      _reportUnhandled(error, stackTrace);
    }
  }

  // --------------------------------------------------------------- outbound

  void _respondOk(int id, Object? result) {
    if (_closeReason != null) return;
    try {
      _send(_encode(FrameKind.response, id, {'ok': true, 'r': result}));
    } on IpcException catch (e) {
      _respondError(id, e.error);
    }
  }

  void _respondError(int id, IpcError error) {
    if (_closeReason != null) return;
    _send(_encode(FrameKind.response, id, {'ok': false, 'e': error.toJson()}));
  }

  Uint8List _encode(FrameKind kind, int id, Map<String, Object?> payload) {
    final Uint8List bytes;
    try {
      bytes = utf8.encode(jsonEncode(payload));
    } on JsonUnsupportedObjectError catch (e) {
      throw IpcException.code(
        IpcErrorCode.invalidParams,
        'payload is not JSON-encodable: ${e.unsupportedObject.runtimeType}',
      );
    }
    if (bytes.length + FrameLayout.headerBytes > options.maxFrameBytes) {
      throw IpcException.code(
        IpcErrorCode.messageTooLarge,
        'frame of ${bytes.length} bytes exceeds ${options.maxFrameBytes}',
      );
    }
    return encodeFrame(kind, id, bytes);
  }

  void _send(Uint8List bytes) {
    if (_closeReason != null) return;
    _outQueue.add(bytes);
    stats.framesOut++;
    stats.bytesOut += bytes.length;
    stats.unflushedBytes += bytes.length;
    unawaited(_pump());
  }

  /// Drains [_outQueue] in batches: add everything queued, flush, repeat.
  /// Runs until the queue is empty even after the channel closed, so a
  /// final response still reaches the peer before the sink is closed.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_outQueue.isNotEmpty) {
        final batch = _outQueue;
        _outQueue = [];
        var batchBytes = 0;
        for (final chunk in batch) {
          _output.add(chunk);
          batchBytes += chunk.length;
        }
        await _output.flush();
        stats.unflushedBytes -= batchBytes;
      }
    } catch (error) {
      _outQueue = [];
      stats.unflushedBytes = 0;
      _fail(ChannelCloseReason(ChannelCloseKind.transportError, '$error'));
    } finally {
      _pumping = false;
      _pumpIdle?.complete();
      _pumpIdle = null;
    }
  }

  // ------------------------------------------------------------- lifecycle

  void _fail(ChannelCloseReason reason) {
    if (_closeReason != null) return;
    _closeReason = reason;
    _subscription.cancel();
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final p in pending) {
      p.timer.cancel();
      p.completer.completeError(
        IpcException.code(
          IpcErrorCode.closed,
          '${p.method}: channel closed ($reason)',
        ),
      );
    }
    _outputClosed = _closeOutput();
    _done.complete();
  }

  Future<void> _closeOutput() async {
    while (_pumping) {
      await (_pumpIdle ??= Completer<void>()).future;
    }
    try {
      await _output.close();
    } catch (_) {
      // The peer may already be gone; there is nobody left to report to.
    }
  }

  int _allocateId() {
    var id = _nextId;
    do {
      id = id >= FrameLayout.maxId ? 1 : id + 1;
    } while (_pending.containsKey(id));
    _nextId = id;
    return id;
  }

  void _reportUnhandled(Object error, StackTrace stackTrace) {
    final handler = onUnhandledError;
    if (handler != null) {
      handler(error, stackTrace);
    } else {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  static String _truncate(String text) =>
      text.length <= 512 ? text : '${text.substring(0, 512)}…';
}

final class _Pending {
  _Pending(this.completer, this.timer, this.method);

  final Completer<Object?> completer;
  final Timer timer;
  final String method;
}
