import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_package/src/zip/crc32.dart';
import 'package:ayu_package/src/zip/zip_reader.dart';
import 'package:ayu_package/src/zip/zip_writer.dart';
import 'package:test/test.dart';

Future<File> writeZip(Directory dir, void Function(ZipWriter zip) build, {String name = 'a.zip'}) async {
  final file = File('${dir.path}/$name');
  final sink = file.openWrite();
  final zip = ZipWriter(sink);
  build(zip);
  await zip.finish();
  await sink.close();
  return file;
}

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('ayu_zip_test_'));
  tearDown(() => temp.delete(recursive: true));

  test('crc32 matches the reference value for "123456789"', () {
    expect(Crc32.compute(ascii.encode('123456789')), 0xCBF43926);
    final partial = Crc32.update(Crc32.update(0, ascii.encode('1234')), ascii.encode('56789'));
    expect(partial, 0xCBF43926);
  });

  test('writer output is readable with stored and deflated entries', () async {
    final compressible = Uint8List.fromList(List.filled(50000, 0x41));
    final random = Uint8List.fromList(List.generate(300, (i) => (i * 7919) & 0xFF));
    final file = await writeZip(temp, (zip) {
      zip.addFile('manifest.json', utf8.encode('{"a":1}'));
      zip.addFile('big.txt', compressible);
      zip.addFile('raw.bin', random, compress: false);
      zip.addFile('empty', Uint8List(0));
    });
    final reader = await ZipReader.open(file);
    try {
      expect(reader.entries.map((e) => e.name), ['manifest.json', 'big.txt', 'raw.bin', 'empty']);
      final big = reader.entries[1];
      expect(big.method, 8);
      expect(big.compressedSize, lessThan(big.uncompressedSize));
      expect(reader.entries[2].method, 0);
      expect(await reader.readEntry(reader.entries[0]), utf8.encode('{"a":1}'));
      expect(await reader.readEntry(big), compressible);
      expect(await reader.readEntry(reader.entries[2]), random);
      expect(await reader.readEntry(reader.entries[3]), isEmpty);
    } finally {
      await reader.close();
    }
  });

  test('writer output is byte-for-byte reproducible', () async {
    Future<List<int>> build(String name) async {
      final file = await writeZip(temp, (zip) {
        zip.addFile('b.txt', utf8.encode('bbb'));
        zip.addFile('a.txt', Uint8List.fromList(List.filled(1000, 1)));
      }, name: name);
      return file.readAsBytes();
    }

    expect(await build('one.zip'), await build('two.zip'));
  });

  test('detects a corrupted data byte through CRC', () async {
    final file = await writeZip(temp, (zip) => zip.addFile('x.bin', Uint8List.fromList(List.generate(2000, (i) => i & 0xFF)), compress: false));
    final bytes = await file.readAsBytes();
    bytes[40] ^= 0xFF;
    await file.writeAsBytes(bytes);
    final reader = await ZipReader.open(file);
    try {
      await expectLater(reader.readEntry(reader.entries.single),
          throwsA(isA<ZipFormatException>().having((e) => e.message, 'message', contains('CRC'))));
    } finally {
      await reader.close();
    }
  });

  test('rejects truncated archives', () async {
    final file = await writeZip(temp, (zip) => zip.addFile('x', utf8.encode('hello')));
    final bytes = await file.readAsBytes();
    await file.writeAsBytes(bytes.sublist(0, bytes.length - 3));
    expect(ZipReader.open(file), throwsA(isA<ZipFormatException>()));
  });

  test('rejects an entry count above the limit', () async {
    final file = await writeZip(temp, (zip) {
      for (var i = 0; i < 5; i++) {
        zip.addFile('f$i', utf8.encode('$i'));
      }
    });
    expect(ZipReader.open(file, limits: const ZipLimits(maxEntries: 4)), throwsA(isA<ZipFormatException>()));
  });

  test('rejects encrypted and unknown-method entries as unsupported', () async {
    final file = await writeZip(temp, (zip) => zip.addFile('x', utf8.encode('hello'), compress: false));
    final bytes = await file.readAsBytes();
    // Central directory flags live 8 bytes after the central signature.
    final central = _indexOf(bytes, [0x50, 0x4B, 0x01, 0x02]);
    bytes[central + 8] |= 0x01;
    await file.writeAsBytes(bytes);
    expect(ZipReader.open(file), throwsA(isA<ZipFormatException>().having((e) => e.unsupported, 'unsupported', isTrue)));

    bytes[central + 8] &= ~0x01;
    bytes[central + 10] = 12;
    await file.writeAsBytes(bytes);
    expect(ZipReader.open(file), throwsA(isA<ZipFormatException>().having((e) => e.unsupported, 'unsupported', isTrue)));
  });

  test('refuses to inflate past the declared size (bomb guard)', () async {
    final file = await writeZip(temp, (zip) => zip.addFile('x', Uint8List.fromList(List.filled(100000, 0))));
    final bytes = await file.readAsBytes();
    final central = _indexOf(bytes, [0x50, 0x4B, 0x01, 0x02]);
    // Shrink the declared uncompressed size to 10 bytes.
    bytes.setRange(central + 24, central + 28, [10, 0, 0, 0]);
    await file.writeAsBytes(bytes);
    final reader = await ZipReader.open(file);
    try {
      await expectLater(reader.readEntry(reader.entries.single),
          throwsA(isA<ZipFormatException>().having((e) => e.message, 'message', contains('beyond'))));
    } finally {
      await reader.close();
    }
  });

  test('refuses non-ZIP files', () async {
    final file = File('${temp.path}/text.ayu')..writeAsStringSync('this is not a zip archive at all, just text' * 3);
    expect(ZipReader.open(file), throwsA(isA<ZipFormatException>()));
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('needle not found');
}
