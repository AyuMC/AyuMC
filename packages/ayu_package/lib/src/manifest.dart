import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import 'contracts.dart';
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
    this.packageType = PackageType.plugin,
    List<String> profiles = const [],
    List<EventContractSpec> provides = const [],
    List<ContractRequirement> events = const [],
  })  : authors = List.unmodifiable(authors),
        artifacts = Map.unmodifiable(artifacts),
        dependencies = List.unmodifiable(dependencies),
        capabilities = Set.unmodifiable(capabilities),
        profiles = List.unmodifiable(profiles),
        provides = List.unmodifiable(provides),
        events = List.unmodifiable(events);

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

  final PackageType packageType;

  /// Server profile ids this package supports. Empty means any profile.
  /// Event packs must name at least one, since they read protocol internals.
  final List<String> profiles;

  /// Contracts an event pack provides. Empty for plugins.
  final List<EventContractSpec> provides;

  /// Contracts a plugin consumes (required and optional).
  final List<ContractRequirement> events;

  bool get isEventPack => packageType == PackageType.eventPack;

  ArtifactSpec? artifactFor(RuntimeTarget target) => artifacts[target.id];

  Iterable<DependencySpec> get requiredDependencies =>
      dependencies.where((d) => !d.optional);

  Iterable<ContractRequirement> get requiredEvents => events.where((e) => !e.optional);
  Iterable<ContractRequirement> get optionalEvents => events.where((e) => e.optional);

  /// Every internal primitive this pack's contracts draw from.
  Set<String> get primitiveSources => {for (final c in provides) ...c.sources};

  bool supportsProfile(String profileId) => profiles.isEmpty || profiles.contains(profileId);

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
    final packageType = v.packageType('packageType');
    final capabilities = v.capabilities('capabilities', packageType);
    final profiles = v.stringList('profiles', maxLength: 128);
    final provides = v.provides('provides', packageType);
    final events = v.events('events', packageType);
    if (packageType == PackageType.eventPack && profiles.isEmpty) {
      v.problem('profiles', 'an event pack must name the server profile(s) it supports');
    }
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
      packageType: packageType,
      profiles: profiles,
      provides: provides,
      events: events,
    );
  }

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'packageType': packageType.wireName,
    'id': id,
    'name': name,
    'version': version.toString(),
    if (profiles.isNotEmpty) 'profiles': profiles,
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
    if (provides.isNotEmpty) 'provides': [for (final c in provides) c.toJson()],
    if (events.isNotEmpty)
      'events': {
        if (requiredEvents.isNotEmpty) 'requires': [for (final e in requiredEvents) e.toJson()],
        if (optionalEvents.isNotEmpty) 'optional': [for (final e in optionalEvents) e.toJson()],
      },
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

  PackageType packageType(String field) {
    final value = json[field];
    if (value == null) return PackageType.plugin;
    final type = value is String ? PackageType.fromWire(value) : null;
    if (type == null) {
      problem(field, 'unknown value "$value"; expected ${PackageType.values.map((t) => '"${t.wireName}"').join(' or ')}');
      return PackageType.plugin;
    }
    return type;
  }

  Set<String> capabilities(String field, PackageType type) {
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
      if (type == PackageType.plugin && _eventPackOnlyCapabilities.contains(capability)) {
        problem(field, 'capability "$capability" is reserved for event packs');
        continue;
      }
      result.add(capability);
    }
    return result;
  }

  List<EventContractSpec> provides(String field, PackageType type) {
    final value = json[field];
    if (value == null) {
      if (type == PackageType.eventPack) problem(field, 'an event pack must provide at least one contract');
      return const [];
    }
    if (type == PackageType.plugin) {
      problem(field, 'only event packs provide contracts; set packageType to "event-pack"');
      return const [];
    }
    if (value is! List) {
      problem(field, 'must be a list of contract objects');
      return const [];
    }
    if (value.isEmpty) problem(field, 'an event pack must provide at least one contract');
    final result = <EventContractSpec>[];
    final seen = <String>{};
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      final where = '$field[$i]';
      if (item is! Map) {
        problem(where, 'must be an object');
        continue;
      }
      final map = item.cast<String, Object?>();
      final id = map['id'];
      if (id is! String || !ContractNaming.contractIdPattern.hasMatch(id) || ContractNaming.isPrimitive(id)) {
        problem('$where.id', 'must be a namespaced lowercase identifier such as "player.joined" (the "core." namespace is reserved)');
        continue;
      }
      if (!seen.add(id)) {
        problem('$where.id', '"$id" is declared more than once');
        continue;
      }
      final versionText = map['version'];
      Version? version;
      if (versionText is String) {
        try {
          version = Version.parse(versionText);
        } on FormatException {
          problem('$where.version', '"$versionText" is not a semantic version');
        }
      } else {
        problem('$where.version', 'is required');
      }
      final delivery = DeliverySpec.fromJson(map['delivery'], (m) => problem('$where.delivery', m));
      final sources = map['sources'];
      final sourceList = <String>[];
      if (sources != null) {
        if (sources is! List || !sources.every((s) => s is String)) {
          problem('$where.sources', 'must be a list of primitive ids');
        } else {
          for (final source in sources.cast<String>()) {
            if (!ContractNaming.isPrimitive(source) || !ContractNaming.contractIdPattern.hasMatch(source)) {
              problem('$where.sources', '"$source" is not an internal primitive id (expected "core.…")');
              continue;
            }
            sourceList.add(source);
          }
        }
      }
      final schema = <String, String>{};
      final rawSchema = map['schema'];
      if (rawSchema != null) {
        if (rawSchema is! Map) {
          problem('$where.schema', 'must be an object of field -> type');
        } else {
          for (final entry in rawSchema.entries) {
            if (entry.key is! String || !ContractNaming.schemaTypes.contains(entry.value)) {
              problem('$where.schema', 'field "${entry.key}" has unknown type "${entry.value}"; known: ${ContractNaming.schemaTypes.join(', ')}');
              continue;
            }
            schema[entry.key as String] = entry.value as String;
          }
        }
      }
      final description = map['description'];
      if (description != null && description is! String) problem('$where.description', 'must be a string');
      if (version == null || delivery == null) continue;
      result.add(EventContractSpec(
        id: id,
        version: version,
        delivery: delivery,
        sources: sourceList,
        schema: schema,
        description: description as String?,
      ));
    }
    return result;
  }

  List<ContractRequirement> events(String field, PackageType type) {
    final value = json[field];
    if (value == null) return const [];
    if (type == PackageType.eventPack) {
      problem(field, 'event packs provide contracts; they do not consume them');
      return const [];
    }
    if (value is! Map) {
      problem(field, 'must be an object with "requires" and/or "optional" lists');
      return const [];
    }
    final map = value.cast<String, Object?>();
    final result = <ContractRequirement>[];
    final seen = <String>{};
    for (final key in map.keys) {
      if (key != 'requires' && key != 'optional') {
        problem('$field.$key', 'unknown key; use "requires" or "optional"');
      }
    }
    void parseList(String key, bool optional) {
      final list = map[key];
      if (list == null) return;
      if (list is! List) {
        problem('$field.$key', 'must be a list of {id, version} objects');
        return;
      }
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        final where = '$field.$key[$i]';
        if (item is! Map) {
          problem(where, 'must be an object');
          continue;
        }
        final id = item['id'];
        final range = item['version'];
        if (id is! String || !ContractNaming.contractIdPattern.hasMatch(id) || ContractNaming.isPrimitive(id)) {
          problem('$where.id', 'must be a namespaced contract id such as "player.joined"');
          continue;
        }
        if (!seen.add(id)) {
          problem('$where.id', '"$id" is listed more than once');
          continue;
        }
        if (range is! String) {
          problem('$where.version', 'is required');
          continue;
        }
        try {
          result.add(ContractRequirement(id: id, version: VersionConstraint.parse(range), optional: optional));
        } on FormatException {
          problem('$where.version', '"$range" is not a version constraint');
        }
      }
    }

    parseList('requires', false);
    parseList('optional', true);
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
  static const _knownCapabilities = <String>{'commands', 'events', 'config', 'observe', 'publish'};
  static const _eventPackOnlyCapabilities = <String>{'observe', 'publish'};
}
