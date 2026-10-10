import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_package/src/zip/zip_writer.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const target = RuntimeTarget(TargetOs.windows, TargetArch.x64);
final artifactBytes = Uint8List.fromList(List.generate(4096, (i) => (i * 31) & 0xFF));

PluginManifest manifestFor(ArtifactSpec artifact, {String id = 'demo', String version = '1.0.0'}) => PluginManifest(
  id: id,
  name: 'Demo',
  version: Version.parse(version),
  api: VersionConstraint.parse('^1.0.0'),
  entryPoint: 'src/bin/main.dart',
  artifacts: {artifact.target.id: artifact},
  capabilities: const {'commands'},
);

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('ayu_pkg_test_'));
  tearDown(() => temp.delete(recursive: true));

  Future<File> writePackage({PluginManifest? manifest, Map<String, Uint8List>? extra}) async {
    final artifact = PackageWriter.describeArtifact(target: target, bytes: artifactBytes, dartSdk: Version(3, 13, 4));
    final file = File('${temp.path}/demo.ayu');
    await PackageWriter.write(
      output: file,
      manifest: manifest ?? manifestFor(artifact),
      entries: {
        artifact.path: artifactBytes,
        'src/bin/main.dart': utf8.encode('void main() {}'),
        'src/lib/demo.dart': utf8.encode('class Demo {}'),
        'config/config.json': utf8.encode('{"greeting":"hi"}'),
        ...?extra,
      },
    );
    return file;
  }

  test('opens, validates and extracts a well-formed package', () async {
    final file = await writePackage();
    final package = await AyuPackage.open(file);
    try {
      expect(package.manifest.id, 'demo');
      expect(package.entries.map((e) => e.name), containsAll(['manifest.json', 'bin/windows-x64/plugin.aot', 'src/lib/demo.dart']));
      await package.verifyArtifacts();
      final extracted = await package.extractTo(Directory('${temp.path}/out'));
      expect(await extracted.artifactFile(package.manifest.artifactFor(target)!).readAsBytes(), artifactBytes);
      expect(await File('${temp.path}/out/config/config.json').readAsString(), '{"greeting":"hi"}');
      expect(await File('${temp.path}/out/manifest.json').exists(), isTrue);
    } finally {
      await package.close();
    }
  });

  test('refuses to extract into a non-empty directory', () async {
    final file = await writePackage();
    final package = await AyuPackage.open(file);
    final dest = Directory('${temp.path}/busy')..createSync();
    File('${dest.path}/x').writeAsStringSync('x');
    try {
      await expectLater(package.extractTo(dest), throwsA(isA<PackageException>()
          .having((e) => e.code, 'code', PackageErrorCode.destinationNotEmpty)));
    } finally {
      await package.close();
    }
  });

  test('detects a tampered artifact by digest and removes the partial extraction', () async {
    final artifact = PackageWriter.describeArtifact(target: target, bytes: artifactBytes, dartSdk: Version(3, 13, 4));
    final tampered = Uint8List.fromList(artifactBytes)..[0] ^= 1;
    final file = File('${temp.path}/tampered.ayu');
    final sink = file.openWrite();
    final zip = ZipWriter(sink);
    zip.addFile('manifest.json', utf8.encode(manifestFor(artifact).toJsonString()));
    zip.addFile(artifact.path, tampered);
    await zip.finish();
    await sink.close();

    final package = await AyuPackage.open(file);
    try {
      await expectLater(package.verifyArtifacts(), throwsA(isA<PackageException>()
          .having((e) => e.code, 'code', PackageErrorCode.artifactMismatch)));
      final dest = Directory('${temp.path}/out');
      await expectLater(package.extractTo(dest), throwsA(isA<PackageException>()
          .having((e) => e.code, 'code', PackageErrorCode.artifactMismatch)));
      expect(dest.existsSync(), isFalse);
    } finally {
      await package.close();
    }
  });

  test('rejects a package whose manifest declares a missing artifact', () async {
    final artifact = PackageWriter.describeArtifact(target: target, bytes: artifactBytes, dartSdk: Version(3, 13, 4));
    final file = File('${temp.path}/missing.ayu');
    final sink = file.openWrite();
    final zip = ZipWriter(sink);
    zip.addFile('manifest.json', utf8.encode(manifestFor(artifact).toJsonString()));
    await zip.finish();
    await sink.close();
    expect(AyuPackage.open(file), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.artifactMissing)));
  });

  test('rejects a package without a manifest', () async {
    final file = File('${temp.path}/nomanifest.ayu');
    final sink = file.openWrite();
    final zip = ZipWriter(sink);
    zip.addFile('src/a.dart', utf8.encode('x'));
    await zip.finish();
    await sink.close();
    expect(AyuPackage.open(file), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.manifestMissing)));
  });

  test('rejects traversal and case-duplicate entries', () async {
    Future<File> raw(String name, List<String> names) async {
      final file = File('${temp.path}/$name');
      final sink = file.openWrite();
      final zip = ZipWriter(sink);
      zip.addFile('manifest.json', utf8.encode('{}'));
      for (final n in names) {
        zip.addFile(n, utf8.encode('x'));
      }
      await zip.finish();
      await sink.close();
      return file;
    }

    expect(AyuPackage.open(await raw('t1.ayu', ['../evil.dart'])), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.unsafeEntryPath)));
    expect(AyuPackage.open(await raw('t2.ayu', ['/abs'])), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.unsafeEntryPath)));
    expect(AyuPackage.open(await raw('t3.ayu', ['src/A.dart', 'src/a.dart'])), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.duplicateEntry)));
  });

  test('enforces size and entry limits', () async {
    final file = await writePackage();
    expect(AyuPackage.open(file, limits: const PackageLimits(maxCompressedBytes: 100)),
        throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.tooLarge)));
    expect(AyuPackage.open(file, limits: const PackageLimits(maxEntries: 2)),
        throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.tooManyEntries)));
    expect(AyuPackage.open(file, limits: const PackageLimits(maxUncompressedBytes: 100)),
        throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.tooLarge)));
  });

  test('reports a missing file and a non-archive clearly', () async {
    expect(AyuPackage.open(File('${temp.path}/absent.ayu')), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.notFound)));
    final text = File('${temp.path}/text.ayu')..writeAsStringSync('not an archive' * 10);
    expect(AyuPackage.open(text), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.invalidArchive)));
  });

  test('writer refuses inconsistent artifacts', () async {
    final artifact = PackageWriter.describeArtifact(target: target, bytes: artifactBytes, dartSdk: Version(3, 13, 4));
    expect(
      PackageWriter.write(output: File('${temp.path}/x.ayu'), manifest: manifestFor(artifact), entries: {artifact.path: Uint8List(3)}),
      throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.artifactMismatch)),
    );
    expect(
      PackageWriter.write(output: File('${temp.path}/y.ayu'), manifest: manifestFor(artifact), entries: {}),
      throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.artifactMissing)),
    );
  });
}
