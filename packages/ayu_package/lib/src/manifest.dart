import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';
import 'integrity.dart';
import 'spec.dart';
import 'target.dart';

/// A compiled runtime artifact for one target.
final class ArtifactSpec {
  const ArtifactSpec({
    required this.target,
    required this.path,
    required this.sha256,
    required this.size,
    required this.dartSdk,
  });

  final RuntimeTarget target;

  /// Archive-relative path, `/`-separated.
  final String path;
  final String sha256;
  final int size;

  /// Exact Dart SDK version that produced the snapshot. AOT snapshots only
  /// run on the `dartaotruntime` of the same version.
  final Version dartSdk;

  Map<String, Object?> toJson() => {
    'path': path,
    'sha256': sha256,
    'size': size,
    'dartSdk': dartSdk.toString(),
  };
}

final class DependencySpec {
  const DependencySpec({
    required this.id,
    required this.version,
    this.optional = false,
  });

  final String id;
  final VersionConstraint version;
  final bool optional;

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version.toString(),
    if (optional) 'optional': true,
  };
}

final class BuildInfo {
  const BuildInfo({
    required this.tool,
    required this.toolVersion,
    required this.dartSdk,
    required this.createdAt,
  });

  final String tool;
  final String toolVersion;
  final String dartSdk;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'tool': tool,
    'toolVersion': toolVersion,
    'dartSdk': dartSdk,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// Parsed and validated `manifest.json`.
final class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.api,
    this.formatVersion = PackageSpec.currentFormatVersion,
    this.description,
    List<String> authors = const [],
    this.homepage,
    this.license,
    this.entryPoint,
    Map<String, ArtifactSpec> artifacts = const {},
    List<DependencySpec> dependencies = const [],
    Set<String> capabilities = const {},
    this.build,
  })  : authors = List.unmodifiable(authors),
        artifacts = Map.unmodifiable(artifacts),
        dependencies = List.unmodifiable(dependencies),
        capabilities = Set.unmodifiable(capabilities);

  final int formatVersion;
  final String id;
  final String name;
  final Version version;
  final String? description;
  final List<String> authors;
  final String? homepage;
  final String? license;

  /// Range of host plugin-API versions this plugin was written against.
  final VersionConstraint api;

  /// Archive-relative path of the source entry point (informational).
  final String? entryPoint;

  /// Artifacts keyed by target id.
  final Map<String, ArtifactSpec> artifacts;
  final List<DependencySpec> dependencies;
  final Set<String> capabilities;
  final BuildInfo? build;

  ArtifactSpec? artifactFor(RuntimeTarget target) => artifacts[target.id];

  Iterable<DependencySpec> get requiredDependencies =>
      dependencies.where((d) => !d.optional);

  /// Parses and validates. Throws [PackageException] with
  /// [PackageErrorCode.manifestInvalid] listing every problem found.
  static PluginManifest parse(String json, {PackageLimits limits = const PackageLimits()}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw PackageException(PackageErrorCode.manifestInvalid,
          'manifest is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const PackageException(
          PackageErrorCode.manifestInvalid, 'manifest root must be a JSON object');
    }
    return fromJson(decoded.cast<String, Object?>(), limits: limits);
  }

  static PluginManifest fromJson(Map<String, Object?> json,
      {PackageLimits limits = const PackageLimits()}) {
    final v = _Validator(json, limits);
    final formatVersion = v.formatVersion();
    if (formatVersion != null &&
        !PackageSpec.supportedFormatVersions.contains(formatVersion)) {
      v.problem('formatVersion',
          'unsupported value $formatVersion; this host reads ${PackageSpec.supportedFormatVersions.join(', ')}');
    }
    final id = v.pluginId('id');
    final name = v.requiredString('name', maxLength: 128);
    final version = v.version('version');
    final api = v.constraint('api');
    final description = v.optionalString('description', maxLength: 4096);
    final authors = v.stringList('authors', maxLength: 128);
    final homepage = v.optionalString('homepage', maxLength: 2048);
    final license = v.optionalString('license', maxLength: 256);
    final entryPoint = v.optionalString('entryPoint', maxLength: limits.maxEntryNameLength);
    if (entryPoint != null && !isSafeArchivePath(entryPoint, limits)) {
      v.problem('entryPoint', 'is not a safe archive-relative path');
    }
    final artifacts = v.artifacts('artifacts');
    final dependencies = v.dependencies('dependencies', selfId: id);
    final capabilities = v.capabilities('capabilities');
    final build = v.build('build');
    v.throwIfProblems();
    return PluginManifest(
      formatVersion: formatVersion!,
      id: id!,
      name: name!,
      version: version!,
      api: api!,
      description: description,
      authors: authors,
      homepage: homepage,
      license: license,
      entryPoint: entryPoint,
      artifacts: artifacts,
      dependencies: dependencies,
      capabilities: capabilities,
      build: build,
    );
  }

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'id': id,
    'name': name,
    'version': version.toString(),
    if (description != null) 'description': description,
    if (authors.isNotEmpty) 'authors': authors,
    if (homepage != null) 'homepage': homepage,
    if (license != null) 'license': license,
    'api': api.toString(),
    if (entryPoint != null) 'entryPoint': entryPoint,
    'artifacts': {for (final e in artifacts.entries) e.key: e.value.toJson()},
    if (dependencies.isNotEmpty)
      'dependencies': [for (final d in dependencies) d.toJson()],
    if (capabilities.isNotEmpty) 'capabilities': capabilities.toList()..sort(),
    if (build != null) 'build': build!.toJson(),
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Returns `true` when [path] is a `/`-separated relative path without
  /// traversal, absolute roots, drive letters, control characters or
  /// Windows-reserved names.
  static bool isSafeArchivePath(String path, PackageLimits limits) =>
      describeUnsafeArchivePath(path, limits) == null;

  /// Returns `null` for a safe path, otherwise the reason it is rejected.
  static String? describeUnsafeArchivePath(String path, PackageLimits limits) {
    if (path.isEmpty) return 'empty name';
    if (path.length > limits.maxEntryNameLength) {
      return 'name longer than ${limits.maxEntryNameLength} characters';
    }
    if (path.startsWith('/')) return 'absolute path';
    if (path.contains('\\')) return 'backslash in name';
    if (path.contains('\u0000')) return 'NUL character in name';
    if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return 'drive letter in name';
    for (final unit in path.codeUnits) {
      if (unit < 0x20 || unit == 0x7F) return 'control character in name';
    }
    final segments = path.split('/');
    final isDirectory = path.endsWith('/');
    final effective = isDirectory ? segments.sublist(0, segments.length - 1) : segments;
    if (effective.length > limits.maxPathDepth) {
      return 'deeper than ${limits.maxPathDepth} directories';
    }
    for (final segment in effective) {
      if (segment.isEmpty) return 'empty path segment';
      if (segment == '.' || segment == '..') return 'relative segment "$segment"';
      if (segment.endsWith('.') || segment.endsWith(' ')) {
        return 'segment "$segment" ends with a dot or space';
      }
      final stem = segment.split('.').first.toUpperCase();
      if (_windowsReservedNames.contains(stem)) {
        return 'segment "$segment" is a reserved Windows device name';
      }
      for (final ch in const ['<', '>', ':', '"', '|', '?', '*']) {
        if (segment.contains(ch)) return 'character "$ch" is not portable';
      }
    }
    return null;
  }

  static const _windowsReservedNames = <String>{
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
}

/// Collects problems instead of failing on the first one, so a developer
/// sees every mistake in a single run.
final class _Validator {
  _Validator(this.json, this.limits);

  final Map<String, Object?> json;
  final PackageLimits limits;
  final List<String> problems = [];

  void problem(String field, String message) => problems.add('$field: $message');

  void throwIfProblems() {
    if (problems.isEmpty) return;
    throw PackageException(PackageErrorCode.manifestInvalid,
        '${problems.length} manifest problem(s)',
        problems: List.unmodifiable(problems));
  }

  int? formatVersion() {
    final value = json['formatVersion'];
    if (value is int) return value;
    problem('formatVersion', 'is required and must be an integer');
    return null;
  }

  String? requiredString(String field, {required int maxLength}) {
    final value = json[field];
    if (value is! String || value.trim().isEmpty) {
      problem(field, 'is required and must be a non-empty string');
      return null;
    }
    if (value.length > maxLength) {
      problem(field, 'is longer than $maxLength characters');
      return null;
    }
    return value;
  }

  String? optionalString(String field, {required int maxLength}) {
    final value = json[field];
    if (value == null) return null;
    if (value is! String) {
      problem(field, 'must be a string');
      return null;
    }
    if (value.length > maxLength) {
      problem(field, 'is longer than $maxLength characters');
      return null;
    }
    return value;
  }

  String? pluginId(String field) {
    final value = requiredString(field, maxLength: 64);
    if (value == null) return null;
    if (!PackageSpec.pluginIdPattern.hasMatch(value)) {
      problem(field, '"$value" is invalid; ${PackageSpec.pluginIdRule}');
      return null;
    }
    return value;
  }

  Version? version(String field) {
    final value = requiredString(field, maxLength: 64);
    if (value == null) return null;
    try {
      return Version.parse(value);
    } on FormatException {
      problem(field, '"$value" is not a semantic version');
      return null;
    }
  }

  VersionConstraint? constraint(String field) {
    final value = requiredString(field, maxLength: 128);
    if (value == null) return null;
    try {
      final parsed = VersionConstraint.parse(value);
      if (parsed.isEmpty) {
        problem(field, '"$value" matches no version');
        return null;
      }
      return parsed;
    } on FormatException {
      problem(field, '"$value" is not a version constraint');
      return null;
    }
  }

  List<String> stringList(String field, {required int maxLength}) {
    final value = json[field];
    if (value == null) return const [];
    if (value is! List || !value.every((e) => e is String && e.length <= maxLength)) {
      problem(field, 'must be a list of strings (max $maxLength characters each)');
      return const [];
    }
    return value.cast<String>();
  }

  Map<String, ArtifactSpec> artifacts(String field) {
    final value = json[field];
    if (value == null) return const {};
    if (value is! Map) {
      problem(field, 'must be an object keyed by target id');
      return const {};
    }
    if (value.length > limits.maxArtifacts) {
      problem(field, 'declares more than ${limits.maxArtifacts} artifacts');
      return const {};
    }
    final result = <String, ArtifactSpec>{};
    final seenPaths = <String>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        problem(field, 'keys must be strings');
        continue;
      }
      final target = RuntimeTarget.tryParse(key);
      if (target == null) {
        problem('$field.$key', 'is not a known target (expected <os>-<arch>)');
        continue;
      }
      final body = entry.value;
      if (body is! Map) {
        problem('$field.$key', 'must be an object');
        continue;
      }
      final map = body.cast<String, Object?>();
      final path = map['path'];
      final sha = map['sha256'];
      final size = map['size'];
      final sdk = map['dartSdk'];
      var ok = true;
      if (path is! String ||
          !PluginManifest.isSafeArchivePath(path, limits) ||
          path.endsWith('/')) {
        problem('$field.$key.path', 'must be a safe archive-relative file path');
        ok = false;
      } else if (!seenPaths.add(path)) {
        problem('$field.$key.path', 'is used by more than one artifact');
        ok = false;
      }
      if (sha is! String || !Integrity.sha256Pattern.hasMatch(sha)) {
        problem('$field.$key.sha256', 'must be 64 lowercase hex characters');
        ok = false;
      }
      if (size is! int || size <= 0 || size > limits.maxEntryBytes) {
        problem('$field.$key.size', 'must be a positive integer up to ${limits.maxEntryBytes}');
        ok = false;
      }
      Version? sdkVersion;
      if (sdk is String) {
        try {
          sdkVersion = Version.parse(sdk);
        } on FormatException {
          problem('$field.$key.dartSdk', '"$sdk" is not a semantic version');
          ok = false;
        }
      } else {
        problem('$field.$key.dartSdk', 'is required');
        ok = false;
      }
      if (!ok) continue;
      result[key] = ArtifactSpec(
        target: target,
        path: path as String,
        sha256: sha as String,
        size: size as int,
        dartSdk: sdkVersion!,
      );
    }
    return result;
  }

  List<DependencySpec> dependencies(String field, {required String? selfId}) {
    final value = json[field];
    if (value == null) return const [];
    if (value is! List) {
      problem(field, 'must be a list of {id, version, optional?} objects');
      return const [];
    }
    if (value.length > limits.maxDependencies) {
      problem(field, 'declares more than ${limits.maxDependencies} dependencies');
      return const [];
    }
    final result = <DependencySpec>[];
    final seen = <String>{};
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      if (item is! Map) {
        problem('$field[$i]', 'must be an object');
        continue;
      }
      final map = item.cast<String, Object?>();
      final id = map['id'];
      final range = map['version'];
      final optional = map['optional'] ?? false;
      if (id is! String || !PackageSpec.pluginIdPattern.hasMatch(id)) {
        problem('$field[$i].id', 'is not a valid plugin id');
        continue;
      }
      if (id == selfId) {
        problem('$field[$i].id', 'a plugin cannot depend on itself');
        continue;
      }
      if (!seen.add(id)) {
        problem('$field[$i].id', '"$id" is listed more than once');
        continue;
      }
      if (optional is! bool) {
        problem('$field[$i].optional', 'must be a boolean');
        continue;
      }
      VersionConstraint constraint;
      if (range is! String) {
        problem('$field[$i].version', 'is required');
        continue;
      }
      try {
        constraint = VersionConstraint.parse(range);
      } on FormatException {
        problem('$field[$i].version', '"$range" is not a version constraint');
        continue;
      }
      result.add(DependencySpec(id: id, version: constraint, optional: optional));
    }
    return result;
  }

  Set<String> capabilities(String field) {
    final value = json[field];
    if (value == null) return const {};
    if (value is! List || !value.every((e) => e is String)) {
      problem(field, 'must be a list of strings');
      return const {};
    }
    final result = <String>{};
    for (final capability in value.cast<String>()) {
      if (!_knownCapabilities.contains(capability)) {
        problem(field,
            'unknown capability "$capability"; this host knows ${_knownCapabilities.join(', ')}');
        continue;
      }
      result.add(capability);
    }
    return result;
  }

  BuildInfo? build(String field) {
    final value = json[field];
    if (value == null) return null;
    if (value is! Map) {
      problem(field, 'must be an object');
      return null;
    }
    final map = value.cast<String, Object?>();
    final tool = map['tool'];
    final toolVersion = map['toolVersion'];
    final dartSdk = map['dartSdk'];
    final createdAt = map['createdAt'];
    if (tool is! String || toolVersion is! String || dartSdk is! String || createdAt is! String) {
      problem(field, 'requires string fields tool, toolVersion, dartSdk, createdAt');
      return null;
    }
    final parsed = DateTime.tryParse(createdAt);
    if (parsed == null) {
      problem('$field.createdAt', 'is not an ISO-8601 timestamp');
      return null;
    }
    return BuildInfo(tool: tool, toolVersion: toolVersion, dartSdk: dartSdk, createdAt: parsed);
  }

  /// Mirrors `PluginCapability.all` in `ayu_ipc`. Kept here so the package
  /// layer stays free of the IPC dependency; the host verifies both sets
  /// agree at start-up.
  static const _knownCapabilities = <String>{'commands', 'events', 'config'};
}
