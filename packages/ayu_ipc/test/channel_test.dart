import 'dart:async';
import 'dart:typed_data';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:test/test.dart';

/// In-memory pipe: bytes added on one side arrive on the other.
final class _Pipe implements FrameSink {
  final StreamController<List<int>> controller = StreamController<List<int>>();

  @override
  void add(List<int> bytes) => controller.add(bytes);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() => controller.close();
}

final class _Loopback {
  _Loopback({ChannelOptions options = const ChannelOptions()}) {
    final aToB = _Pipe();
    final bToA = _Pipe();
    a = FrameChannel(input: bToA.controller.stream, output: aToB, options: options, debugName: 'a');
    b = FrameChannel(input: aToB.controller.stream, output: bToA, options: options, debugName: 'b');
    rawToB = aToB;
  }

  late final FrameChannel a;
  late final FrameChannel b;
  late final _Pipe rawToB;

  Future<void> close() async {
    await a.close();
    await b.close();
  }
}

void main() {
  late _Loopback loop;

  setUp(() => loop = _Loopback());
  tearDown(() => loop.close());

  test('request/response round-trips JSON params and results', () async {
    loop.b.onRequest = (method, params) => {'echo': method, 'params': params};
    final result = await loop.a.request('ping', {'n': 1});
    expect(result, {'echo': 'ping', 'params': {'n': 1}});
    expect(loop.a.stats.framesOut, 1);
    expect(loop.a.stats.framesIn, 1);
  });

  test('notifications are delivered one-way', () async {
    final received = Completer<(String, Object?)>();
    loop.b.onNotification = (method, params) => received.complete((method, params));
    expect(loop.a.notify('tick', {'t': 2}), isTrue);
    final (method, params) = await received.future;
    expect(method, 'tick');
    expect(params, {'t': 2});
  });

  test('missing handler yields method_not_found', () async {
    await expectLater(
      loop.a.request('nope'),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.methodNotFound)),
    );
  });

  test('IpcException thrown by a handler is forwarded with its code', () async {
    loop.b.onRequest = (_, _) => throw IpcException.code(IpcErrorCode.capabilityDenied, 'no');
    await expectLater(
      loop.a.request('x'),
      throwsA(isA<IpcException>()
          .having((e) => e.code, 'code', IpcErrorCode.capabilityDenied)
          .having((e) => e.message, 'message', 'no')),
    );
  });

  test('other handler errors become internal errors and keep the channel open', () async {
    loop.b.onRequest = (_, _) => throw StateError('boom');
    await expectLater(
      loop.a.request('x'),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.internal)),
    );
    expect(loop.a.isOpen, isTrue);
    loop.b.onRequest = (_, _) => 'fine';
    expect(await loop.a.request('x'), 'fine');
  });

  test('requests time out without the peer answering', () async {
    loop.b.onRequest = (_, _) => Completer<Object?>().future;
    await expectLater(
      loop.a.request('slow', null, const Duration(milliseconds: 50)),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.timeout)),
    );
  });

  test('pending request limit is enforced', () async {
    await loop.close();
    loop = _Loopback(options: const ChannelOptions(maxPendingRequests: 2));
    loop.b.onRequest = (_, _) => Completer<Object?>().future;
    final first = loop.a.request('a').catchError((_) => null);
    final second = loop.a.request('b').catchError((_) => null);
    expect(
      () => loop.a.request('c'),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.tooManyRequests)),
    );
    await loop.close();
    await Future.wait([first, second]);
  });

  test('closing fails pending requests with closed', () async {
    loop.b.onRequest = (_, _) => Completer<Object?>().future;
    final pending = loop.a.request('x', null, const Duration(seconds: 30));
    await loop.b.close();
    await expectLater(
      pending,
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.closed)),
    );
    await loop.a.done;
    expect(loop.a.closeReason?.kind, ChannelCloseKind.eof);
  });

  test('a corrupt byte stream closes the channel with a protocol error', () async {
    loop.rawToB.add([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0]);
    await loop.b.done;
    expect(loop.b.closeReason?.kind, ChannelCloseKind.protocolError);
    expect(loop.b.notify('x'), isFalse);
  });

  test('a frame with non-JSON payload closes the channel', () async {
    loop.rawToB.add(encodeFrame(FrameKind.notification, 0, Uint8List.fromList([0x7B, 0x7D, 0x7D])));
    await loop.b.done;
    expect(loop.b.closeReason?.kind, ChannelCloseKind.protocolError);
  });

  test('oversized outgoing requests are rejected locally', () async {
    await loop.close();
    loop = _Loopback(options: const ChannelOptions(maxFrameBytes: 64));
    expect(
      () => loop.a.request('big', 'x' * 100),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.messageTooLarge)),
    );
    expect(loop.a.notify('big', 'x' * 100), isFalse);
    expect(loop.a.stats.droppedNotifications, 1);
  });

  test('inbound in-flight limit answers with too_many_requests', () async {
    await loop.close();
    loop = _Loopback(options: const ChannelOptions(maxInFlightInbound: 1));
    final gate = Completer<Object?>();
    loop.b.onRequest = (_, _) => gate.future;
    final first = loop.a.request('a');
    await expectLater(
      loop.a.request('b'),
      throwsA(isA<IpcException>().having((e) => e.code, 'code', IpcErrorCode.tooManyRequests)),
    );
    gate.complete('done');
    expect(await first, 'done');
    expect(loop.b.stats.rejectedInbound, 1);
  });

  test('notification handler errors are reported, not fatal', () async {
    final reported = Completer<Object>();
    loop.b.onUnhandledError = (error, _) => reported.complete(error);
    loop.b.onNotification = (_, _) => throw StateError('handler failed');
    loop.a.notify('x');
    expect(await reported.future, isA<StateError>());
    expect(loop.b.isOpen, isTrue);
  });
}
