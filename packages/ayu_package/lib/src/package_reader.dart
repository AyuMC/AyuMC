import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'integrity.dart';
import 'manifest.dart';
import 'spec.dart';
import 'target.dart';
import 'zip/zip_reader.dart';

/// Result of a successful extraction.
final class ExtractedPackage {
  const ExtractedPackage({required this.directory, required this.manifest});

  final Directory directory;
  final PluginManifest manifest;

  File artifactFile(ArtifactSpec artifact) =>
      File(p.joinAll([directory.path, ...artifact.path.split('/')]));
}

/// A validated `.ayu` archive. Opening performs every structural and
/// manifest check; nothing is executed or extracted until asked.
final class AyuPackage {
  AyuPackage._(this.file, this._reader, this.manifest, this._entries, this.limits);

  final File file;
  final ZipReader _reader;
  final PluginManifest manifest;
  final Map<String, ZipEntry> _entries;
  final PackageLimits limits;

  Iterable<ZipEntry> get entries => _entries.values;

  bool hasEntry(String path) => _entries.containsKey(path);

  static Future<AyuPackage> open(File file, {PackageLimits limits = const PackageLimits()}) async {
    if (!await file.exists()) {
      throw PackageException(PackageErrorCode.notFound, 'package file not found: ${file.path}');
    }
    final length = await file.length();
    if (length > limits.maxCompressedBytes) {
      throw PackageException(PackageErrorCode.tooLarge,
          'package is $length bytes; the limit is ${limits.maxCompressedBytes}');
    }
    final ZipReader reader;
    try {
      reader = await ZipReader.open(file,
          limits: ZipLimits(
            maxEntries: limits.maxEntries,
            maxCentralDirectoryBytes: limits.maxCentralDirectoryBytes,
            maxEntryBytes: limits.maxEntryBytes,
          ));
    } on ZipLimitException catch (e) {
      throw PackageException(
          switch (e.kind) {
            ZipLimitKind.entries => PackageErrorCode.tooManyEntries,
            ZipLimitKind.centralDirectory => PackageErrorCode.tooLarge,
            ZipLimitKind.entrySize => PackageErrorCode.entryTooLarge,
          },
          e.message);
    } on ZipFormatException catch (e) {
      throw PackageException(
          e.unsupported ? PackageErrorCode.unsupportedArchiveFeature : PackageErrorCode.invalidArchive,
          e.message);
    } on FileSystemException catch (e) {
      throw PackageException(PackageErrorCode.ioError, 'cannot read package: ${e.message}');
    }
    try {
      final entries = _validateEntries(reader.entries, limits);
      final manifest = await _readManifest(reader, entries, limits);
      _checkArtifactEntries(manifest, entries);
      return AyuPackage._(file, reader, manifest, entries, limits);
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  Future<void> close() => _reader.close();

  Future<Uint8List> readEntry(String path) async {
    final entry = _entries[path];
    if (entry == null || entry.isDirectory) {
      throw PackageException(PackageErrorCode.notFound, 'no file entry "$path" in package');
    }
    try {
      return await _reader.readEntry(entry);
    } on ZipFormatException catch (e) {
      throw PackageException(PackageErrorCode.invalidArchive, e.message);
    }
  }

  /// Hashes every declared artifact and compares it with the manifest.
  Future<void> verifyArtifacts() async {
    for (final artifact in manifest.artifacts.values) {
      final entry = _entries[artifact.path]!;
      final digest = Integrity.sink();
      try {
        await _reader.readEntryTo(entry, digest);
      } on ZipFormatException catch (e) {
        throw PackageException(PackageErrorCode.invalidArchive, e.message);
      }
      digest.close();
      if (digest.value != artifact.sha256) {
        throw PackageException(PackageErrorCode.artifactMismatch,
            'artifact "${artifact.path}" for ${artifact.target.id} does not match its manifest sha256');
      }
    }
  }

  /// Extracts every entry into [destination], which must not exist or must
  /// be empty. Artifact digests are verified while writing. On any failure
  /// the destination is removed again and a [PackageException] is thrown.
  Future<ExtractedPackage> extractTo(Directory destination) async {
    if (await destination.exists() && !await destination.list().isEmpty) {
      throw PackageException(PackageErrorCode.destinationNotEmpty,
          'destination "${destination.path}" is not empty');
    }
    final root = p.normalize(p.absolute(destination.path));
    try {
      await destination.create(recursive: true);
      final artifactsByPath = {for (final a in manifest.artifacts.values) a.path: a};
      for (final entry in _entries.values) {
        final target = p.joinAll([root, ...entry.name.split('/').where((s) => s.isNotEmpty)]);
        if (!p.isWithin(root, target)) {
          throw PackageException(PackageErrorCode.unsafeEntryPath,
              'entry "${entry.name}" resolves outside the destination');
        }
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(p.dirname(target)).create(recursive: true);
        final artifact = artifactsByPath[entry.name];
        await _writeEntry(entry, File(target), artifact);
      }
      return ExtractedPackage(directory: Directory(root), manifest: manifest);
    } catch (error) {
      await _removeQuietly(Directory(root));
      if (error is PackageException) rethrow;
      if (error is ZipFormatException) {
        throw PackageException(PackageErrorCode.invalidArchive, error.message);
      }
      throw PackageException(PackageErrorCode.extractionFailed, 'extraction failed: $error');
    }
  }

  Future<void> _writeEntry(ZipEntry entry, File target, ArtifactSpec? artifact) async {
    final io = target.openWrite();
    final digest = artifact == null ? null : Integrity.sink();
    try {
      await _reader.readEntryTo(entry, _TeeSink(io, digest));
      await io.flush();
    } finally {
      await io.close();
    }
    if (digest != null) {
      digest.close();
      if (digest.value != artifact!.sha256) {
        throw PackageException(PackageErrorCode.artifactMismatch,
            'artifact "${artifact.path}" for ${artifact.target.id} does not match its manifest sha256');
      }
    }
  }

  static Map<String, ZipEntry> _validateEntries(List<ZipEntry> entries, PackageLimits limits) {
    if (entries.length > limits.maxEntries) {
      throw PackageException(PackageErrorCode.tooManyEntries,
          'package has ${entries.length} entries; the limit is ${limits.maxEntries}');
    }
    final byName = <String, ZipEntry>{};
    final folded = <String>{};
    var total = 0;
    for (final entry in entries) {
      final reason = PluginManifest.describeUnsafeArchivePath(entry.name, limits);
      if (reason != null) {
        throw PackageException(PackageErrorCode.unsafeEntryPath, 'entry "${entry.name}": $reason');
      }
      final key = entry.name.toLowerCase();
      if (!folded.add(key) || byName.containsKey(entry.name)) {
        throw PackageException(PackageErrorCode.duplicateEntry,
            'entry "${entry.name}" appears more than once (names are compared case-insensitively)');
      }
      if (entry.isDirectory && entry.uncompressedSize != 0) {
        throw PackageException(PackageErrorCode.invalidArchive,
            'directory entry "${entry.name}" carries data');
      }
      if (entry.uncompressedSize > limits.maxEntryBytes) {
        throw PackageException(PackageErrorCode.entryTooLarge,
            'entry "${entry.name}" is ${entry.uncompressedSize} bytes; the limit is ${limits.maxEntryBytes}');
      }
      total += entry.uncompressedSize;
      if (total > limits.maxUncompressedBytes) {
        throw PackageException(PackageErrorCode.tooLarge,
            'package expands to more than ${limits.maxUncompressedBytes} bytes');
      }
      byName[entry.name] = entry;
    }
    return byName;
  }

  static Future<PluginManifest> _readManifest(
      ZipReader reader, Map<String, ZipEntry> entries, PackageLimits limits) async {
    final entry = entries[PackageSpec.manifestFileName];
    if (entry == null || entry.isDirectory) {
      throw PackageException(PackageErrorCode.manifestMissing,
          'package has no ${PackageSpec.manifestFileName} at its root');
    }
    if (entry.uncompressedSize > limits.maxManifestBytes) {
      throw PackageException(PackageErrorCode.manifestInvalid,
          'manifest is ${entry.uncompressedSize} bytes; the limit is ${limits.maxManifestBytes}');
    }
    final Uint8List bytes;
    try {
      bytes = await reader.readEntry(entry);
    } on ZipFormatException catch (e) {
      throw PackageException(PackageErrorCode.invalidArchive, e.message);
    }
    final String text;
    try {
      text = const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      throw const PackageException(PackageErrorCode.manifestInvalid, 'manifest is not valid UTF-8');
    }
    return PluginManifest.parse(text, limits: limits);
  }

  static void _checkArtifactEntries(PluginManifest manifest, Map<String, ZipEntry> entries) {
    for (final artifact in manifest.artifacts.values) {
      final entry = entries[artifact.path];
      if (entry == null || entry.isDirectory) {
        throw PackageException(PackageErrorCode.artifactMissing,
            'manifest declares artifact "${artifact.path}" for ${artifact.target.id} but the archive has no such file');
      }
      if (entry.uncompressedSize != artifact.size) {
        throw PackageException(PackageErrorCode.artifactMismatch,
            'artifact "${artifact.path}" is ${entry.uncompressedSize} bytes in the archive, manifest says ${artifact.size}');
      }
    }
  }

  static Future<void> _removeQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Best effort; the caller already has the primary error.
    }
  }
}

final class _TeeSink implements Sink<List<int>> {
  _TeeSink(this._primary, this._digest);

  final IOSink _primary;
  final DigestSink? _digest;

  @override
  void add(List<int> data) {
    _primary.add(data);
    _digest?.add(data);
  }

  @override
  void close() {}
}

/// Convenience for callers that only need to know whether a package can run
/// on a given target without opening the archive twice.
extension AyuPackageCompatibility on AyuPackage {
  ArtifactSpec? artifactFor(RuntimeTarget target) => manifest.artifactFor(target);
}
