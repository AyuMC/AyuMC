import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';
import 'integrity.dart';
import 'manifest.dart';
import 'spec.dart';
import 'target.dart';
import 'zip/zip_writer.dart';

/// Authors `.ayu` archives. Output is deterministic for identical inputs:
/// entries are sorted, timestamps fixed, and the manifest is serialised
/// canonically.
abstract final class PackageWriter {
  /// Describes [bytes] as the artifact for [target], computing size and
  /// digest.
  static ArtifactSpec describeArtifact({
    required RuntimeTarget target,
    required Uint8List bytes,
    required Version dartSdk,
    String? archivePath,
  }) =>
      ArtifactSpec(
        target: target,
        path: archivePath ?? PackageSpec.artifactPath(target.id),
        sha256: Integrity.sha256Hex(bytes),
        size: bytes.length,
        dartSdk: dartSdk,
      );

  /// Writes [manifest] plus [entries] (archive path -> bytes) to [output].
  /// Every manifest artifact must be present in [entries] with matching
  /// size and digest; the manifest entry itself is generated.
  static Future<void> write({
    required File output,
    required PluginManifest manifest,
    required Map<String, Uint8List> entries,
    PackageLimits limits = const PackageLimits(),
    int compressionLevel = 6,
    DateTime? timestamp,
  }) async {
    if (entries.containsKey(PackageSpec.manifestFileName)) {
      throw const PackageException(PackageErrorCode.duplicateEntry,
          'the manifest entry is generated and must not be supplied');
    }
    for (final name in entries.keys) {
      final reason = PluginManifest.describeUnsafeArchivePath(name, limits);
      if (reason != null || name.endsWith('/')) {
        throw PackageException(PackageErrorCode.unsafeEntryPath,
            'entry "$name": ${reason ?? 'directory entries are implicit'}');
      }
    }
    for (final artifact in manifest.artifacts.values) {
      final bytes = entries[artifact.path];
      if (bytes == null) {
        throw PackageException(PackageErrorCode.artifactMissing,
            'artifact "${artifact.path}" for ${artifact.target.id} was not supplied');
      }
      if (bytes.length != artifact.size || Integrity.sha256Hex(bytes) != artifact.sha256) {
        throw PackageException(PackageErrorCode.artifactMismatch,
            'artifact "${artifact.path}" does not match the manifest size/sha256');
      }
    }
    if (entries.length + 1 > limits.maxEntries) {
      throw PackageException(PackageErrorCode.tooManyEntries,
          'package would have ${entries.length + 1} entries; the limit is ${limits.maxEntries}');
    }

    await output.parent.create(recursive: true);
    final sink = output.openWrite();
    try {
      final zip = ZipWriter(sink, compressionLevel: compressionLevel, timestamp: timestamp);
      zip.addFile(PackageSpec.manifestFileName, utf8.encode(manifest.toJsonString()));
      final names = entries.keys.toList()..sort();
      for (final name in names) {
        zip.addFile(name, entries[name]!);
      }
      await zip.finish();
    } finally {
      await sink.close();
    }
  }
}
