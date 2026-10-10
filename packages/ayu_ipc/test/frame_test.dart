import 'dart:typed_data';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:test/test.dart';

void main() {
  group('encodeFrame', () {
    test('writes big-endian header followed by payload', () {
      final bytes = encodeFrame(
        FrameKind.request,
        0x01020304,
        Uint8List.fromList([9, 8]),
      );
      expect(bytes, [0, 0, 0, 7, 1, 1, 2, 3, 4, 9, 8]);
    });
  });

  group('FrameDecoder', () {
    test('decodes frames split at every byte boundary', () {
      final a = encodeFrame(
        FrameKind.request,
        1,
        Uint8List.fromList([1, 2, 3]),
      );
      final b = encodeFrame(FrameKind.notification, 0, Uint8List(0));
      final c = encodeFrame(
        FrameKind.response,
        0xFFFFFFFF,
        Uint8List.fromList([7]),
      );
      final stream = Uint8List.fromList([...a, ...b, ...c]);

      for (var split = 1; split < stream.length; split++) {
        final decoder = FrameDecoder(maxFrameBytes: 64);
        final frames = [
          ...decoder.addChunk(stream.sublist(0, split)),
          ...decoder.addChunk(stream.sublist(split)),
        ];
        expect(frames, hasLength(3), reason: 'split at $split');
        expect(frames[0].kind, FrameKind.request);
        expect(frames[0].id, 1);
        expect(frames[0].payload, [1, 2, 3]);
        expect(frames[1].kind, FrameKind.notification);
        expect(frames[1].payload, isEmpty);
        expect(frames[2].id, 0xFFFFFFFF);
        expect(frames[2].payload, [7]);
        expect(decoder.bufferedBytes, 0);
      }
    });

    test('returned payloads do not alias the internal buffer', () {
      final decoder = FrameDecoder(maxFrameBytes: 64);
      final first = decoder
          .addChunk(
            encodeFrame(FrameKind.request, 1, Uint8List.fromList([1, 1])),
          )
          .single;
      decoder.addChunk(
        encodeFrame(FrameKind.request, 2, Uint8List.fromList([2, 2])),
      );
      expect(first.payload, [1, 1]);
    });

    test('rejects frames above the size limit before buffering them', () {
      final decoder = FrameDecoder(maxFrameBytes: 16);
      final oversized = encodeFrame(FrameKind.request, 1, Uint8List(12));
      expect(
        () => decoder.addChunk(oversized.sublist(0, 4)),
        throwsA(isA<FrameFormatException>()),
      );
      expect(() => decoder.addChunk([0]), throwsA(isA<FrameFormatException>()));
    });

    test('rejects a length shorter than the header', () {
      final decoder = FrameDecoder(maxFrameBytes: 16);
      expect(
        () => decoder.addChunk([0, 0, 0, 4]),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('rejects unknown frame kinds', () {
      final decoder = FrameDecoder(maxFrameBytes: 16);
      expect(
        () => decoder.addChunk([0, 0, 0, 5, 9, 0, 0, 0, 1]),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('grows its buffer for large frames', () {
      final decoder = FrameDecoder(maxFrameBytes: 1 << 20);
      final payload = Uint8List(200000);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }
      final frames = decoder.addChunk(
        encodeFrame(FrameKind.notification, 0, payload),
      );
      expect(frames.single.payload, payload);
    });
  });
}
