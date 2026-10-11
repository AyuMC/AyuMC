import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Directory layout under the plugin root:
///
/// ```text
/// <root>/installed/<id>/<version>/   extracted packages
/// <root>/staging/<token>/            in-progress extractions (purged at start)
/// <root>/data/<id>/                  plugin-owned persistent data
/// <root>/state.json                  installed versions and desired state
/// ```
final class PluginStoreLayout {
  PluginStoreLayout(Directory root)
    : root = Directory(p.normalize(p.absolute(root.path)));

  final Directory root;

  Directory get installed => Directory(p.join(root.path, 'installed'));
  Directory get staging => Directory(p.join(root.path, 'staging'));
  Directory get data => Directory(p.join(root.path, 'data'));
  File get stateFile => File(p.join(root.path, 'state.json'));

  Directory pluginDirectory(String id) => Directory(p.join(installed.path, id));
  Directory installDirectory(String id, Version version) =>
      Directory(p.join(installed.path, id, version.toString()));
  Directory dataDirectory(String id) => Directory(p.join(data.path, id));
}

/// Persisted desired state of one installed plugin. `enabled` is what the
/// user asked for; the live state lives on the instance.
final class InstalledPluginRecord {
  const InstalledPluginRecord({
    required this.id,
    required this.version,
    required this.enabled,
  });

  final String id;
  final Version version;
  final bool enabled;

  InstalledPluginRecord copyWith({Version? version, bool? enabled}) =>
      InstalledPluginRecord(
        id: id,
        version: version ?? this.version,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version.toString(),
    'enabled': enabled,
  };
}

/// An installed plugin found on disk together with its manifest.
final class StoredPlugin {
  const StoredPlugin({
    required this.record,
    required this.manifest,
    required this.installDirectory,
  });

  final InstalledPluginRecord record;
  final PluginManifest manifest;
  final Directory installDirectory;
}

/// Filesystem side of the host: staging, atomic commit of extracted
/// packages and the persisted state file.
final class PluginStore {
  PluginStore(Directory root, {required Logger log})
    : layout = PluginStoreLayout(root),
      _log = log;

  static const _stateFormatVersion = 1;

  final PluginStoreLayout layout;
  final Logger _log;
  final Map<String, InstalledPluginRecord> _records = {};
  final Random _random = Random.secure();

  Map<String, InstalledPluginRecord> get records => Map.unmodifiable(_records);

  /// Creates the layout, discards leftovers of interrupted installations
  /// and loads the state file.
  Future<void> open() async {
    for (final dir in [
      layout.root,
      layout.installed,
      layout.staging,
      layout.data,
    ]) {
      await dir.create(recursive: true);
    }
    await for (final leftover in layout.staging.list()) {
      _log.warn('removing interrupted staging directory ${leftover.path}');
      await _deleteQuietly(leftover);
    }
    await _loadState();
  }

  Future<Directory> createStagingDirectory() async {
    final token =
        '${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36)}-${_random.nextInt(1 << 32).toRadixString(36)}';
    final dir = Directory(p.join(layout.staging.path, token));
    await dir.create();
    return dir;
  }

  /// Moves a fully extracted staging directory into its final location.
  /// Fails if the destination exists.
  ///
  /// Windows often refuses the first rename while a scanner still has a
  /// handle on a file that was just written. Retry, then copy if needed.
  Future<Directory> commit({
    required Directory staged,
    required String id,
    required Version version,
  }) async {
    final destination = layout.installDirectory(id, version);
    if (await destination.exists()) {
      await _deleteQuietly(staged);
      throw PackageException(
        PackageErrorCode.destinationNotEmpty,
        'version $version of "$id" is already installed at ${destination.path}',
      );
    }
    await destination.parent.create(recursive: true);
    FileSystemException? lastFailure;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        return await staged.rename(destination.path);
      } on FileSystemException catch (error) {
        lastFailure = error;
        if (!await staged.exists()) break;
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
      }
    }
    if (await staged.exists()) {
      try {
        await _copyTree(staged, destination);
        await _deleteQuietly(staged);
        return destination;
      } on FileSystemException catch (error) {
        lastFailure = error;
        await _deleteQuietly(destination);
      }
    }
    await _deleteQuietly(staged);
    final os = lastFailure?.osError;
    final detail = os == null
        ? (lastFailure?.message ?? 'unknown error')
        : '${lastFailure!.message} (os ${os.errorCode} ${os.message})';
    throw PackageException(
      PackageErrorCode.ioError,
      'cannot move staged package into place: $detail',
    );
  }

  Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, relative);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      }
    }
  }

  Future<void> discard(Directory staged) => _deleteQuietly(staged);

  Future<void> put(InstalledPluginRecord record) async {
    _records[record.id] = record;
    await _saveState();
  }

  Future<void> remove(String id) async {
    if (_records.remove(id) == null) return;
    await _saveState();
  }

  /// Deletes one installed version. The plugin's data directory is kept.
  Future<void> deleteInstalled(String id, Version version) async {
    await _deleteQuietly(layout.installDirectory(id, version));
    final parent = layout.pluginDirectory(id);
    if (await parent.exists() && await parent.list().isEmpty) {
      await _deleteQuietly(parent);
    }
  }

  /// Reads every recorded plugin's manifest from disk. Records whose files
  /// are missing or unreadable are dropped from the state with a warning.
  Future<List<StoredPlugin>> loadInstalled({
    PackageLimits limits = const PackageLimits(),
  }) async {
    final result = <StoredPlugin>[];
    var dirty = false;
    for (final record in List.of(_records.values)) {
      final dir = layout.installDirectory(record.id, record.version);
      final manifestFile = File(p.join(dir.path, PackageSpec.manifestFileName));
      try {
        final manifest = PluginManifest.parse(
          await manifestFile.readAsString(),
          limits: limits,
        );
        if (manifest.id != record.id || manifest.version != record.version) {
          throw PackageException(
            PackageErrorCode.manifestInvalid,
            'manifest identifies ${manifest.id} ${manifest.version}, state expects ${record.id} ${record.version}',
          );
        }
        result.add(
          StoredPlugin(
            record: record,
            manifest: manifest,
            installDirectory: dir,
          ),
        );
      } on FileSystemException catch (e) {
        _log.error(
          'dropping "${record.id}" from state: cannot read ${manifestFile.path} (${e.message})',
        );
        _records.remove(record.id);
        dirty = true;
      } on PackageException catch (e) {
        _log.error('dropping "${record.id}" from state: $e');
        _records.remove(record.id);
        dirty = true;
      }
    }
    if (dirty) await _saveState();
    return result;
  }

  Future<void> _loadState() async {
    final file = layout.stateFile;
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['formatVersion'] != _stateFormatVersion) {
        throw const FormatException('unknown state format');
      }
      final plugins = decoded['plugins'];
      if (plugins is! List)
        throw const FormatException('plugins must be a list');
      for (final item in plugins) {
        if (item is! Map)
          throw const FormatException('plugin entry must be an object');
        final id = item['id'];
        final version = item['version'];
        final enabled = item['enabled'];
        if (id is! String || version is! String || enabled is! bool) {
          throw const FormatException('plugin entry has wrong field types');
        }
        _records[id] = InstalledPluginRecord(
          id: id,
          version: Version.parse(version),
          enabled: enabled,
        );
      }
    } on FormatException catch (e) {
      final backup = File('${file.path}.corrupt');
      _log.error(
        'state file is unreadable (${e.message}); moving it to ${backup.path} and starting empty',
      );
      await file.rename(backup.path);
      _records.clear();
    }
  }

  /// Writes the state through a temporary file and a rename so a crash
  /// mid-write never leaves a truncated state file behind.
  Future<void> _saveState() async {
    final file = layout.stateFile;
    final temp = File('${file.path}.tmp');
    final json = const JsonEncoder.withIndent('  ').convert({
      'formatVersion': _stateFormatVersion,
      'plugins': [for (final r in _records.values) r.toJson()],
    });
    await temp.writeAsString(json, flush: true);
    await temp.rename(file.path);
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on FileSystemException catch (e) {
      _log.warn('cannot delete ${entity.path}: ${e.message}');
    }
  }
}
