import 'dart:convert';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Directory names a library scan must not walk into.
const skippedDirectoryNames = <String>{
  '.git',
  '.dart_tool',
  'node_modules',
  'installed',
  'staging',
  'cache',
  'plugins',
  'events',
  'build',
};

/// The repository that contains `event_packs_src` and `examples`, when the
/// server root is that repository or its `run` directory.
Directory? findRepository(Directory serverRoot) {
  for (final dir in [serverRoot.parent, serverRoot]) {
    if (Directory(p.join(dir.path, 'event_packs_src')).existsSync() ||
        Directory(p.join(dir.path, 'examples')).existsSync()) {
      return dir;
    }
  }
  return null;
}

/// One `.ayu` file the catalog could not validate. Other files are still listed.
final class DiscoveryFailure {
  const DiscoveryFailure({required this.path, required this.message});

  final String path;
  final String message;
}

/// A validated archive in the package library. Discovery does not install or execute it.
final class LibraryPackage {
  LibraryPackage({
    required this.file,
    required this.manifest,
    List<String> blockers = const [],
    List<String> warnings = const [],
  }) : blockers = List.of(blockers),
       warnings = List.of(warnings);

  final File file;
  final PluginManifest manifest;
  final List<String> blockers;
  final List<String> warnings;

  bool get compatible => blockers.isEmpty;
}

/// An installed package, either live from [PluginHost] or read from the store while the server is stopped.
final class InstalledPackage {
  const InstalledPackage({
    required this.manifest,
    required this.enabled,
    required this.installDirectory,
    required this.dataDirectory,
    this.state,
    this.lastError,
    this.stderrTail = '',
    this.pid,
    this.restartCount = 0,
    this.droppedEvents = 0,
    this.subscribers = const [],
    this.configState = '',
    this.configRevision = 0,
    this.configSchema,
    this.configError,
  });

  final PluginManifest manifest;

  /// Desired state in `state.json`. This is not the same as a running worker.
  final bool enabled;

  /// Null while the server is stopped: the package cannot be executing.
  final PluginState? state;
  final String? lastError;
  final String stderrTail;
  final int? pid;
  final int restartCount;
  final int droppedEvents;

  /// Plugins currently subscribed to a contract this pack provides.
  final List<String> subscribers;
  final String installDirectory;
  final String dataDirectory;

  /// Empty until the worker reports an AyuConfig reload.
  final String configState;
  final int configRevision;
  final int? configSchema;
  final String? configError;
}

/// Snapshot of what the manager may show. Replaced as a whole after each refresh.
final class Inventory {
  const Inventory({
    this.installed = const [],
    this.library = const [],
    this.failures = const [],
    this.roots = const [],
    this.profileId = 'AyuMC-1.8.9-release',
    this.profileWarning,
    this.serverRunning = false,
    this.runtimeSdk,
    this.scannedAt,
  });

  static const empty = Inventory();

  final List<InstalledPackage> installed;
  final List<LibraryPackage> library;
  final List<DiscoveryFailure> failures;
  final List<String> roots;
  final String profileId;
  final String? profileWarning;
  final bool serverRunning;
  final Version? runtimeSdk;
  final DateTime? scannedAt;

  InstalledPackage? installedById(String id) {
    for (final package in installed) {
      if (package.manifest.id == id) return package;
    }
    return null;
  }
}

/// Facts used to judge a manifest. The artifact SDK is compared only when [runtimeSdk] is known.
final class ScanContext {
  const ScanContext({
    required this.profileId,
    required this.apiVersion,
    required this.target,
    this.runtimeSdk,
  });

  final String profileId;
  final Version apiVersion;
  final RuntimeTarget target;
  final Version? runtimeSdk;
}

/// Why a package cannot be installed or enabled on this server.
List<String> compatibilityBlockers(
  PluginManifest manifest,
  ScanContext context,
) {
  final blockers = <String>[];
  if (!manifest.api.allows(context.apiVersion)) {
    blockers.add(
      'Cannot enable — requires plugin API ${manifest.api}; this host provides ${context.apiVersion}.',
    );
  }
  if (!manifest.supportsProfile(context.profileId)) {
    final listed = manifest.profiles.isEmpty
        ? 'none'
        : manifest.profiles.join(', ');
    blockers.add(
      'Cannot enable — this package supports $listed; this server runs ${context.profileId}.',
    );
  }
  final artifact = manifest.artifactFor(context.target);
  if (artifact == null) {
    final shipped = manifest.artifacts.isEmpty
        ? 'no artifacts'
        : manifest.artifacts.keys.join(', ');
    blockers.add(
      'Cannot enable — unsupported runtime target ${context.target.id} ($shipped).',
    );
  } else if (context.runtimeSdk != null &&
      artifact.dartSdk != context.runtimeSdk) {
    blockers.add(
      'Cannot enable — artifact was built with Dart ${artifact.dartSdk}; this server runs Dart ${context.runtimeSdk}.',
    );
  }
  return blockers;
}

/// Non-blocking notes. An unknown SDK is a warning: the server checks it when it starts.
List<String> compatibilityWarnings(
  PluginManifest manifest,
  ScanContext context,
) {
  final artifact = manifest.artifactFor(context.target);
  if (artifact != null && context.runtimeSdk == null) {
    return [
      'Artifact for ${context.target.id} was built with Dart ${artifact.dartSdk}. The exact SDK is checked when the server starts.',
    ];
  }
  return const [];
}

/// Phrase for the installed or available state. Uses the live [PluginState] when the server is running.
String runtimeLabel({
  required bool installed,
  required bool serverRunning,
  required bool enabled,
  PluginState? state,
  String? error,
  bool updateAvailable = false,
}) {
  final update = updateAvailable ? ' Update available.' : '';
  if (!installed) return 'Available — not installed.';
  if (!serverRunning) {
    return enabled
        ? 'Installed — starts with the server. Not running now.$update'
        : 'Installed — disabled.$update';
  }
  final label = switch (state) {
    PluginState.active => 'Active — running.',
    PluginState.disabled => 'Installed — disabled.',
    PluginState.suspended => 'Suspended — required Event Pack is missing.',
    PluginState.failed => 'Failed — ${error ?? 'the worker did not start.'}',
    PluginState.crashed => 'Crashed — the worker exited.',
    PluginState.starting => 'Starting.',
    PluginState.stopping => 'Disabling.',
    PluginState.staged ||
    PluginState.validating ||
    PluginState.discovered => 'Pending.',
    null => 'Unknown — the runtime did not report a state.',
  };
  return '$label$update';
}

bool matchesQuery(PluginManifest manifest, String filter) {
  final needle = filter.trim().toLowerCase();
  if (needle.isEmpty) return true;
  final hay = [
    manifest.id,
    manifest.name,
    manifest.version.toString(),
    manifest.description ?? '',
    ...manifest.provides.map((contract) => contract.id),
    ...manifest.events.map((event) => event.id),
    ...manifest.dependencies.map((dependency) => dependency.id),
  ].join(' ').toLowerCase();
  return hay.contains(needle);
}

List<InstalledPackage> contractConsumers(
  Inventory inventory,
  PluginManifest provider, {
  bool requiredOnly = true,
}) {
  final ids = provider.provides.map((contract) => contract.id).toSet();
  if (ids.isEmpty) return const [];
  return [
    for (final package in inventory.installed)
      if (!package.manifest.isEventPack &&
          package.manifest.events.any(
            (event) =>
                ids.contains(event.id) && (!requiredOnly || !event.optional),
          ))
        package,
  ];
}

List<InstalledPackage> packageDependents(Inventory inventory, String id) => [
  for (final package in inventory.installed)
    if (package.manifest.id != id &&
        package.manifest.requiredDependencies.any(
          (dependency) => dependency.id == id,
        ))
      package,
];

/// One row in the package list. Headers are not selectable.
final class CatalogRow {
  const CatalogRow.header(this.title)
    : selectable = false,
      subtitle = '',
      badge = '',
      tone = '2',
      library = null,
      installed = null,
      failure = null;

  const CatalogRow.entry({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.tone,
    this.library,
    this.installed,
    this.failure,
  }) : selectable = true;

  final bool selectable;
  final String title;
  final String subtitle;
  final String badge;
  final String tone;
  final LibraryPackage? library;
  final InstalledPackage? installed;
  final DiscoveryFailure? failure;

  String get identity {
    if (failure != null) return 'bad:${failure!.path}';
    if (library != null) return 'lib:${library!.file.path}';
    return 'inst:${installed!.manifest.id}';
  }
}

/// Installed, other versions, available, and problems. Same-version library copies are not repeated.
List<CatalogRow> buildCatalogRows({
  required bool events,
  required Inventory inventory,
  required String filter,
}) {
  bool wanted(PluginManifest manifest) => manifest.isEventPack == events;
  final installedById = <String, InstalledPackage>{
    for (final package in inventory.installed)
      if (wanted(package.manifest)) package.manifest.id: package,
  };
  final installed =
      installedById.values
          .where((package) => matchesQuery(package.manifest, filter))
          .toList()
        ..sort((a, b) => a.manifest.id.compareTo(b.manifest.id));

  final updates = <LibraryPackage>[];
  final available = <LibraryPackage>[];
  final incompatible = <LibraryPackage>[];
  final library =
      inventory.library
          .where(
            (package) =>
                wanted(package.manifest) &&
                matchesQuery(package.manifest, filter),
          )
          .toList()
        ..sort((a, b) {
          final byId = a.manifest.id.compareTo(b.manifest.id);
          return byId != 0
              ? byId
              : a.manifest.version.compareTo(b.manifest.version);
        });
  for (final package in library) {
    final current = installedById[package.manifest.id];
    if (current == null && !package.compatible) {
      incompatible.add(package);
      continue;
    }
    if (current == null) {
      available.add(package);
      continue;
    }
    if (current.manifest.version != package.manifest.version) {
      updates.add(package);
    }
  }

  final needle = filter.trim().toLowerCase();
  final failures = [
    for (final failure in inventory.failures)
      if (needle.isEmpty ||
          '${failure.path} ${failure.message}'.toLowerCase().contains(needle))
        failure,
  ];

  final rows = <CatalogRow>[];
  void addSection(String title, List<CatalogRow> entries) {
    if (entries.isEmpty) return;
    rows.add(CatalogRow.header(title));
    rows.addAll(entries);
  }

  addSection('Installed', [
    for (final package in installed)
      CatalogRow.entry(
        title: package.manifest.id,
        subtitle: package.manifest.version.toString(),
        badge: runtimeLabel(
          installed: true,
          serverRunning: inventory.serverRunning,
          enabled: package.enabled,
          state: package.state,
          error: package.lastError,
          updateAvailable: updates.any(
            (item) =>
                item.manifest.id == package.manifest.id &&
                item.manifest.version > package.manifest.version,
          ),
        ),
        tone: _tone(package, inventory.serverRunning),
        installed: package,
      ),
  ]);
  addSection('Other versions', [
    for (final package in updates)
      CatalogRow.entry(
        title: package.manifest.id,
        subtitle: package.manifest.version.toString(),
        badge:
            package.manifest.version >
                installedById[package.manifest.id]!.manifest.version
            ? 'Update available.'
            : 'Older than installed.',
        tone: '33',
        library: package,
        installed: installedById[package.manifest.id],
      ),
  ]);
  addSection('Available', [
    for (final package in available)
      CatalogRow.entry(
        title: package.manifest.id,
        subtitle: package.manifest.version.toString(),
        badge: 'Available — not installed.',
        tone: '36',
        library: package,
      ),
  ]);
  addSection('Problems', [
    for (final package in incompatible)
      CatalogRow.entry(
        title: package.manifest.id,
        subtitle: package.manifest.version.toString(),
        badge: package.blockers.first,
        tone: '31',
        library: package,
      ),
    for (final failure in failures)
      CatalogRow.entry(
        title: p.basename(failure.path),
        subtitle: '',
        badge: failure.message,
        tone: '31',
        failure: failure,
      ),
  ]);
  return rows;
}

String _tone(InstalledPackage package, bool serverRunning) {
  if (!serverRunning) return package.enabled ? '33' : '90';
  return switch (package.state) {
    PluginState.active => '32',
    PluginState.suspended ||
    PluginState.starting ||
    PluginState.stopping => '33',
    PluginState.failed || PluginState.crashed => '31',
    _ => '90',
  };
}

List<String> describeSelection({
  required Inventory inventory,
  LibraryPackage? library,
  InstalledPackage? installed,
  DiscoveryFailure? failure,
}) {
  if (failure != null) {
    return [
      p.basename(failure.path),
      '',
      'This archive was not added to the catalog.',
      failure.message,
      '',
      failure.path,
      '',
      'Fix or remove the file, then press R.',
    ];
  }
  final manifest = installed?.manifest ?? library?.manifest;
  if (manifest == null) return const ['Nothing selected.'];
  final current = inventory.installedById(manifest.id);
  final lines = <String>[
    manifest.name,
    '${manifest.isEventPack ? 'Event pack' : 'Plugin'}   ${manifest.id}   ${manifest.version}',
    '',
    if (installed != null)
      runtimeLabel(
        installed: true,
        serverRunning: inventory.serverRunning,
        enabled: installed.enabled,
        state: installed.state,
        error: installed.lastError,
        updateAvailable:
            library != null &&
            library.manifest.version > installed.manifest.version,
      )
    else if (current != null && current.manifest.version == manifest.version)
      'Installed — this library copy is the same version.'
    else
      'Available — not installed.',
  ];
  if (manifest.description != null && manifest.description!.isNotEmpty) {
    lines.addAll(['', manifest.description!]);
  }
  lines.addAll([
    '',
    'Profile',
    '  server ${inventory.profileId}',
    '  package ${manifest.profiles.isEmpty ? 'any' : manifest.profiles.join(', ')}',
  ]);
  lines.addAll([
    '',
    'Plugin API',
    '  requires ${manifest.api}',
    '  host ${IpcProtocol.apiVersion}',
  ]);
  final artifact = manifest.artifactFor(RuntimeTarget.current());
  lines.addAll([
    '',
    'Runtime',
    '  target ${RuntimeTarget.current().id}',
    if (artifact == null)
      '  no artifact for this target'
    else
      '  Dart ${artifact.dartSdk}',
    if (inventory.runtimeSdk != null) '  server Dart ${inventory.runtimeSdk}',
  ]);
  if (library != null && library.blockers.isNotEmpty) {
    lines.addAll([
      '',
      'Cannot install',
      for (final blocker in library.blockers) '  $blocker',
    ]);
  }
  if (library != null && library.warnings.isNotEmpty) {
    lines.addAll([
      '',
      'Notes',
      for (final warning in library.warnings) '  $warning',
    ]);
  }
  if (manifest.dependencies.isNotEmpty) {
    lines.addAll([
      '',
      'Dependencies',
      for (final dependency in manifest.dependencies)
        '  ${dependency.id} ${dependency.version}${dependency.optional ? ' (optional)' : ''}',
    ]);
  }
  if (manifest.provides.isNotEmpty) {
    lines.addAll([
      '',
      'Provides',
      for (final contract in manifest.provides)
        '  ${contract.id} ${contract.version}',
    ]);
  }
  if (manifest.events.isNotEmpty) {
    lines.addAll([
      '',
      'Requires events',
      for (final event in manifest.events)
        '  ${event.id} ${event.version}${event.optional ? ' (optional)' : ''}',
    ]);
  }
  if (manifest.isEventPack) {
    final consumers = contractConsumers(
      inventory,
      manifest,
      requiredOnly: false,
    );
    lines.addAll([
      '',
      'Consumers',
      if (consumers.isEmpty) '  no installed plugin declares these contracts',
      for (final consumer in consumers)
        '  ${consumer.manifest.id}  ${_consumerNeed(consumer.manifest, manifest)}',
    ]);
  }
  final dependents = packageDependents(inventory, manifest.id);
  if (dependents.isNotEmpty) {
    lines.addAll([
      '',
      'Required by',
      for (final dependent in dependents) '  ${dependent.manifest.id}',
    ]);
  }
  if (installed != null) {
    lines.addAll([
      '',
      'Runtime',
      '  state ${installed.state?.name ?? 'not running (server stopped)'}',
      '  desired ${installed.enabled ? 'enabled' : 'disabled'}',
      if (installed.pid != null) '  pid ${installed.pid}',
      if (installed.restartCount > 0) '  restarts ${installed.restartCount}',
      if (installed.droppedEvents > 0)
        '  dropped events ${installed.droppedEvents}',
      if (installed.subscribers.isNotEmpty)
        '  subscribed now ${installed.subscribers.join(', ')}',
      if (installed.lastError != null) '  error ${installed.lastError}',
      if (installed.configState.isNotEmpty)
        '  config ${installed.configState} revision ${installed.configRevision}',
      if (installed.configSchema != null)
        '  config schema ${installed.configSchema}',
      if (installed.configError != null)
        '  config error ${installed.configError}',
      if (installed.configState.isNotEmpty)
        '  config file ${installed.dataDirectory}\\config.ayuconf',
    ]);
    final stderr = installed.stderrTail.trim();
    if (stderr.isNotEmpty) {
      final tail = stderr
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      final shown = tail.length > 4 ? tail.sublist(tail.length - 4) : tail;
      lines.addAll([
        '',
        'Worker output',
        for (final line in shown) '  ${line.trim()}',
      ]);
    }
    lines.addAll([
      '',
      'Installed copy',
      '  ${installed.installDirectory}',
      'Data',
      '  ${installed.dataDirectory}',
    ]);
  }
  if (library != null) {
    lines.addAll(['', 'Library file', '  ${library.file.path}']);
  }
  return lines;
}

String _consumerNeed(PluginManifest consumer, PluginManifest provider) {
  final ids = provider.provides.map((contract) => contract.id).toSet();
  final required = consumer.requiredEvents
      .where((event) => ids.contains(event.id))
      .map((event) => event.id);
  if (required.isNotEmpty) return 'requires ${required.join(', ')}';
  final optional = consumer.optionalEvents
      .where((event) => ids.contains(event.id))
      .map((event) => event.id);
  return 'optional ${optional.join(', ')}';
}

final class _CacheEntry {
  const _CacheEntry({
    required this.modifiedMs,
    required this.length,
    this.manifest,
    this.error,
  });

  final int modifiedMs;
  final int length;
  final PluginManifest? manifest;
  final String? error;
}

/// Finds `.ayu` archives in known library locations and validates each one.
///
/// The scan does not walk the installed plugin or event trees, `.git`, or
/// `.dart_tool`. Opening an archive validates it; nothing is executed.
final class PackageScanner {
  PackageScanner({required this.serverRoot, this.repositoryRoot});

  final Directory serverRoot;
  final Directory? repositoryRoot;
  final Map<String, _CacheEntry> _cache = {};

  Directory get libraryDirectory =>
      Directory(p.join(serverRoot.path, 'library'));

  Future<
    ({
      List<LibraryPackage> packages,
      List<DiscoveryFailure> failures,
      List<String> roots,
    })
  >
  scan(ScanContext context) async {
    final failures = <DiscoveryFailure>[];
    final roots = <String>[];
    final files = <File>[];
    final seen = <String>{};

    Future<void> addFile(File file, Directory allowed) async {
      if (!file.path.toLowerCase().endsWith('.ayu')) return;
      if (!await _staysInside(file, allowed)) {
        failures.add(
          DiscoveryFailure(
            path: file.path,
            message:
                'Skipped because the file resolves outside ${allowed.path}.',
          ),
        );
        return;
      }
      final identity = _identity(file.path);
      if (seen.add(identity)) files.add(File(p.normalize(file.absolute.path)));
    }

    final projects = <Directory>[];
    final repository = repositoryRoot;
    if (repository != null) {
      projects.add(Directory(p.join(repository.path, 'event_packs_src')));
      projects.add(Directory(p.join(repository.path, 'examples')));
    }
    for (final root in projects) {
      roots.add(root.path);
      if (!await root.exists()) continue;
      await _scanProjects(root, 0, addFile, failures);
    }

    await libraryDirectory.create(recursive: true);
    roots.add(libraryDirectory.path);
    await _scanLibrary(libraryDirectory, addFile, failures);

    final configured = await _configuredLibraries(failures);
    for (final directory in configured) {
      roots.add(directory.path);
      if (_insideInstallTree(directory)) {
        failures.add(
          DiscoveryFailure(
            path: directory.path,
            message:
                'This library path is inside the installed plugin or event tree and was not scanned.',
          ),
        );
        continue;
      }
      if (!await directory.exists()) {
        failures.add(
          DiscoveryFailure(
            path: directory.path,
            message: 'Configured library directory does not exist.',
          ),
        );
        continue;
      }
      await _scanLibrary(directory, addFile, failures);
    }

    final packages = <LibraryPackage>[];
    final fresh = <String>{};
    for (final file in files) {
      final identity = _identity(file.path);
      fresh.add(identity);
      final inspected = await _inspect(file, identity);
      if (inspected.error != null) {
        failures.add(
          DiscoveryFailure(path: file.path, message: inspected.error!),
        );
        continue;
      }
      final manifest = inspected.manifest!;
      packages.add(
        LibraryPackage(
          file: file,
          manifest: manifest,
          blockers: compatibilityBlockers(manifest, context),
          warnings: compatibilityWarnings(manifest, context),
        ),
      );
    }
    _cache.removeWhere((key, _) => !fresh.contains(key));
    _noteDuplicates(packages);
    return (packages: packages, failures: failures, roots: roots);
  }

  Future<void> _scanProjects(
    Directory parent,
    int depth,
    Future<void> Function(File file, Directory allowed) addFile,
    List<DiscoveryFailure> failures,
  ) async {
    if (depth > 2 || !await parent.exists()) return;
    final built = Directory(p.join(parent.path, 'build', 'ayu'));
    if (await built.exists()) {
      await _listAyu(built, addFile, failures);
    }
    if (depth == 2) return;
    try {
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (skippedDirectoryNames.contains(name)) continue;
        await _scanProjects(
          Directory(entity.path),
          depth + 1,
          addFile,
          failures,
        );
      }
    } on FileSystemException catch (error) {
      failures.add(
        DiscoveryFailure(
          path: parent.path,
          message: 'Cannot read directory: ${error.message}',
        ),
      );
    }
  }

  Future<void> _scanLibrary(
    Directory directory,
    Future<void> Function(File file, Directory allowed) addFile,
    List<DiscoveryFailure> failures,
  ) async {
    if (_insideInstallTree(directory)) return;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) {
          await addFile(entity, directory);
          continue;
        }
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (skippedDirectoryNames.contains(name) ||
            _insideInstallTree(Directory(entity.path))) {
          continue;
        }
        await _listAyu(Directory(entity.path), addFile, failures);
      }
    } on FileSystemException catch (error) {
      failures.add(
        DiscoveryFailure(
          path: directory.path,
          message: 'Cannot read directory: ${error.message}',
        ),
      );
    }
  }

  Future<void> _listAyu(
    Directory directory,
    Future<void> Function(File file, Directory allowed) addFile,
    List<DiscoveryFailure> failures,
  ) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) await addFile(entity, directory);
      }
    } on FileSystemException catch (error) {
      failures.add(
        DiscoveryFailure(
          path: directory.path,
          message: 'Cannot read directory: ${error.message}',
        ),
      );
    }
  }

  Future<List<Directory>> _configuredLibraries(
    List<DiscoveryFailure> failures,
  ) async {
    final file = File(
      p.join(serverRoot.path, 'config', 'package-libraries.json'),
    );
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['directories'] is! List) {
        failures.add(
          DiscoveryFailure(
            path: file.path,
            message:
                'package-libraries.json must be an object with a directories list.',
          ),
        );
        return const [];
      }
      final directories = <Directory>[];
      for (final item in decoded['directories'] as List) {
        if (item is! String || item.trim().isEmpty) continue;
        final raw = item.trim();
        directories.add(
          Directory(
            p.normalize(
              p.absolute(
                p.isAbsolute(raw) ? raw : p.join(serverRoot.path, raw),
              ),
            ),
          ),
        );
      }
      return directories;
    } on FormatException catch (error) {
      failures.add(
        DiscoveryFailure(
          path: file.path,
          message: 'package-libraries.json is not valid JSON: ${error.message}',
        ),
      );
      return const [];
    } on FileSystemException catch (error) {
      failures.add(
        DiscoveryFailure(
          path: file.path,
          message: 'Cannot read package-libraries.json: ${error.message}',
        ),
      );
      return const [];
    }
  }

  bool _insideInstallTree(Directory directory) {
    final path = p.normalize(directory.absolute.path);
    for (final name in ['plugins', 'events']) {
      final root = p.normalize(p.join(serverRoot.path, name));
      if (path == root || p.isWithin(root, path)) return true;
    }
    return false;
  }

  Future<bool> _staysInside(File file, Directory root) async {
    try {
      final resolved = p.normalize(await file.resolveSymbolicLinks());
      final resolvedRoot = p.normalize(await root.resolveSymbolicLinks());
      return resolved == resolvedRoot || p.isWithin(resolvedRoot, resolved);
    } on FileSystemException {
      return false;
    }
  }

  Future<_CacheEntry> _inspect(File file, String identity) async {
    final stat = await file.stat();
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    final cached = _cache[identity];
    if (cached != null &&
        cached.modifiedMs == modifiedMs &&
        cached.length == stat.size) {
      return cached;
    }
    try {
      final opened = await AyuPackage.open(file);
      try {
        await opened.verifyArtifacts();
        final entry = _CacheEntry(
          modifiedMs: modifiedMs,
          length: stat.size,
          manifest: opened.manifest,
        );
        _cache[identity] = entry;
        return entry;
      } finally {
        await opened.close();
      }
    } on PackageException catch (error) {
      final message = error.problems.isEmpty
          ? error.message
          : '${error.message} ${error.problems.join(' ')}';
      final entry = _CacheEntry(
        modifiedMs: modifiedMs,
        length: stat.size,
        error: message,
      );
      _cache[identity] = entry;
      return entry;
    } on FileSystemException catch (error) {
      final entry = _CacheEntry(
        modifiedMs: modifiedMs,
        length: stat.size,
        error: error.message,
      );
      _cache[identity] = entry;
      return entry;
    }
  }

  void _noteDuplicates(List<LibraryPackage> packages) {
    final groups = <String, List<LibraryPackage>>{};
    for (final package in packages) {
      groups
          .putIfAbsent(
            '${package.manifest.id}@${package.manifest.version}',
            () => [],
          )
          .add(package);
    }
    for (final group in groups.values) {
      if (group.length < 2) continue;
      final places = group.map((package) => package.file.path).join('; ');
      for (final package in group) {
        package.warnings.add(
          'Several archives declare ${package.manifest.id} ${package.manifest.version}: $places',
        );
      }
    }
  }

  String _identity(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
