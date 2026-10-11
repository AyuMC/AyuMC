import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_profile/ayu_profile.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'catalog.dart';
import 'server_control.dart';

/// Result of one management action. [ok] is false until the package manager confirms the outcome.
final class DeskResult {
  const DeskResult(this.ok, this.message);

  final bool ok;
  final String message;
}

String explainFailure(Object error) {
  if (error is PluginHostException) {
    final extra = error.details
        .where((detail) => detail.trim().isNotEmpty)
        .join(' · ');
    return extra.isEmpty ? error.message : '${error.message} · $extra';
  }
  if (error is PackageException) {
    final extra = error.problems
        .where((problem) => problem.trim().isNotEmpty)
        .join(' · ');
    return extra.isEmpty ? error.message : '${error.message} · $extra';
  }
  return error.toString();
}

/// Package catalog and lifecycle actions.
///
/// While the server is running, every mutation goes through [PluginHost].
/// While it is stopped, the same plugin and event stores are updated on disk
/// and nothing is reported as executing.
final class PackageDesk {
  PackageDesk({
    required this.control,
    Directory? repositoryRoot,
    this.hostOverride,
  }) : repositoryRoot = repositoryRoot ?? findRepository(control.root),
       scanner = PackageScanner(
         serverRoot: control.root,
         repositoryRoot: repositoryRoot ?? findRepository(control.root),
       );

  final ServerControl control;
  final Directory? repositoryRoot;
  final PackageScanner scanner;

  /// Test hook. When set, the desk uses this host even if [ServerControl] is stopped.
  PluginHost? hostOverride;

  /// Test hook. Awaited at the start of each queued action.
  Future<void> Function()? debugDelay;

  final Logger _log = Logger('Packages');
  Inventory inventory = Inventory.empty;
  String? activity;
  String? profileWarning;

  void Function()? onChanged;

  bool get busy => activity != null;

  PluginHost? get host {
    final override = hostOverride;
    if (override != null) return override;
    if (control.state != ServerRunState.running) return null;
    return control.server?.plugins;
  }

  bool get serverRunning => host != null;

  /// Runs [action] on the same queue as install and refresh, so a start cannot
  /// rewrite the stores while a catalog reload still has them open.
  Future<T> runLocked<T>(Future<T> Function() action) => _queue(action);

  Future<DeskResult> refresh() => _queue(() async {
    activity = 'Refreshing packages…';
    _touch();
    await _reload(rescan: true);
    final count = inventory.library.length;
    final bad = inventory.failures.length;
    if (bad == 0)
      return DeskResult(
        true,
        'Found $count package(s) in the library. Nothing was installed.',
      );
    return DeskResult(
      false,
      'Found $count package(s). $bad file(s) could not be read.',
    );
  });

  Future<void> reload() => _queue(() => _reload());

  Future<DeskResult> install(LibraryPackage package, {required bool enable}) =>
      _queue(() async {
        activity = 'Installing ${package.manifest.id}…';
        _touch();
        return _install(package, enable: enable);
      });

  Future<DeskResult> enable(String id) => _queue(() async {
    activity = 'Enabling $id…';
    _touch();
    return _enable(id);
  });

  Future<DeskResult> disable(String id, {bool cascade = false}) =>
      _queue(() async {
        activity = 'Disabling $id…';
        _touch();
        return _disable(id, cascade: cascade);
      });

  Future<DeskResult> update(LibraryPackage package) => _queue(() async {
    activity = 'Updating ${package.manifest.id}…';
    _touch();
    return _update(package);
  });

  Future<DeskResult> uninstall(String id, {bool cascade = false}) =>
      _queue(() async {
        activity = 'Uninstalling $id…';
        _touch();
        return _uninstall(id, cascade: cascade);
      });

  Future<void> _tail = Future<void>.value();

  Future<T> _queue<T>(Future<T> Function() action) {
    final run = _tail.then((_) async {
      activity ??= 'Working…';
      _touch();
      final delay = debugDelay;
      if (delay != null) await delay();
      try {
        return await action();
      } finally {
        activity = null;
        try {
          await _reload();
        } catch (error, stack) {
          _log.error('package list could not be reloaded: $error\n$stack');
        }
        _touch();
      }
    });
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  void _touch() => onChanged?.call();

  Future<void> _reload({bool rescan = false}) async {
    final context = await _context();
    final previousLibrary = inventory.library;
    final previousFailures = inventory.failures;
    final previousRoots = inventory.roots;
    final scanned = rescan ? await scanner.scan(context) : null;
    final installed = await _readInstalled();
    inventory = Inventory(
      installed: installed,
      library: scanned?.packages ?? previousLibrary,
      failures: scanned?.failures ?? previousFailures,
      roots: scanned?.roots ?? previousRoots,
      profileId: context.profileId,
      profileWarning: profileWarning,
      serverRunning: serverRunning,
      runtimeSdk: context.runtimeSdk,
      scannedAt: rescan ? DateTime.now() : inventory.scannedAt,
    );
  }

  Future<ScanContext> _context() async {
    profileWarning = null;
    final running = control.server;
    var profileId = ProfileCatalog.defaultProfile.id;
    if (control.state == ServerRunState.running && running != null) {
      profileId = running.profile.id;
    } else {
      final file = ServerLayout(control.root).serverConfigFile;
      if (await file.exists()) {
        try {
          profileId = (await ProfileSelection(file).load()).id;
        } on ProfileException catch (error) {
          profileWarning =
              '${error.message} Compatibility used ${ProfileCatalog.defaultProfile.id}.';
        }
      }
    }
    return ScanContext(
      profileId: profileId,
      apiVersion: Version.parse(IpcProtocol.apiVersion),
      target: RuntimeTarget.current(),
      runtimeSdk: host?.runtime?.version,
    );
  }

  Future<List<InstalledPackage>> _readInstalled() async {
    final live = host;
    if (live != null) {
      final packages = <InstalledPackage>[];
      for (final snapshot in live.plugins) {
        packages.add(await _fromSnapshot(snapshot, live));
      }
      return packages;
    }
    final layout = ServerLayout(control.root);
    return [
      ...await _readStore(layout.plugins.root),
      ...await _readStore(layout.events.root),
    ];
  }

  Future<InstalledPackage> _fromSnapshot(
    PluginSnapshot snapshot,
    PluginHost live,
  ) async {
    final manifest = await _manifestOrSnapshot(snapshot);
    final subscribers = <String>{
      for (final contract in manifest.provides)
        ...live.contracts.subscribers(contract.id),
    }.toList()..sort();
    return InstalledPackage(
      manifest: manifest,
      enabled: snapshot.enabled,
      state: snapshot.state,
      lastError: snapshot.lastError,
      stderrTail: snapshot.stderrTail,
      pid: snapshot.pid,
      restartCount: snapshot.restartCount,
      droppedEvents: snapshot.droppedEvents,
      subscribers: subscribers,
      configState: snapshot.configState,
      configRevision: snapshot.configRevision,
      configSchema: snapshot.configSchema,
      configError: snapshot.configError,
      installDirectory: snapshot.installDirectory,
      dataDirectory: snapshot.dataDirectory,
    );
  }

  Future<PluginManifest> _manifestOrSnapshot(PluginSnapshot snapshot) async {
    final file = File(
      p.join(snapshot.installDirectory, PackageSpec.manifestFileName),
    );
    try {
      return PluginManifest.parse(await file.readAsString());
    } on Object {
      return PluginManifest(
        id: snapshot.id,
        name: snapshot.name,
        version: snapshot.version,
        api: VersionConstraint.parse(IpcProtocol.apiVersion),
        packageType: snapshot.packageType,
        capabilities: snapshot.capabilities,
      );
    }
  }

  Future<List<InstalledPackage>> _readStore(Directory root) async {
    final state = File(p.join(root.path, 'state.json'));
    final installed = Directory(p.join(root.path, 'installed'));
    if (!await state.exists() && !await installed.exists()) return const [];
    final store = PluginStore(root, log: _log);
    await store.open();
    final stored = await store.loadInstalled();
    return [
      for (final item in stored)
        InstalledPackage(
          manifest: item.manifest,
          enabled: item.record.enabled,
          installDirectory: item.installDirectory.path,
          dataDirectory: store.layout.dataDirectory(item.record.id).path,
        ),
    ];
  }

  Future<DeskResult> _install(
    LibraryPackage package, {
    required bool enable,
  }) async {
    final fresh = await _revalidate(package);
    if (fresh is DeskResult) return fresh;
    final opened = fresh as AyuPackage;
    try {
      final blockers = compatibilityBlockers(opened.manifest, await _context());
      if (blockers.isNotEmpty) {
        return DeskResult(
          false,
          'Cannot install ${opened.manifest.id}. ${blockers.join(' ')}',
        );
      }
      final live = host;
      if (live != null) {
        try {
          final snapshot = await live.install(opened.file, enable: enable);
          return _installedMessage(snapshot);
        } on PluginHostException catch (error) {
          final snapshot = live.plugin(opened.manifest.id);
          if (snapshot != null) {
            return DeskResult(
              false,
              'Installed ${snapshot.id} ${snapshot.version}, but it is ${snapshot.state.name}. ${explainFailure(error)}',
            );
          }
          return DeskResult(false, explainFailure(error));
        }
      }
      return await _installStopped(opened, enable: enable);
    } finally {
      await opened.close();
    }
  }

  Future<DeskResult> _installStopped(
    AyuPackage opened, {
    required bool enable,
  }) async {
    final manifest = opened.manifest;
    final layout = ServerLayout(control.root);
    final store = PluginStore(
      manifest.isEventPack ? layout.events.root : layout.plugins.root,
      log: _log,
    );
    await store.open();
    final installed = await _readInstalled();
    if (installed.any((package) => package.manifest.id == manifest.id)) {
      final current = installed.firstWhere(
        (package) => package.manifest.id == manifest.id,
      );
      return DeskResult(
        false,
        '${manifest.id} ${current.manifest.version} is already installed. Select the other version and update, or uninstall it first.',
      );
    }
    final dependency = _dependencyProblem(
      manifest,
      installed,
      requireEnabled: enable,
    );
    if (dependency != null) return DeskResult(false, dependency);
    final staging = await store.createStagingDirectory();
    try {
      await opened.extractTo(staging);
    } catch (error) {
      await store.discard(staging);
      return DeskResult(false, explainFailure(error));
    }
    try {
      await store.commit(
        staged: staging,
        id: manifest.id,
        version: manifest.version,
      );
    } on PackageException catch (error) {
      return DeskResult(false, explainFailure(error));
    }
    await store.put(
      InstalledPluginRecord(
        id: manifest.id,
        version: manifest.version,
        enabled: enable,
      ),
    );
    if (enable) {
      final missing = _missingContracts(manifest, installed);
      final waiting = missing.isEmpty
          ? ''
          : ' Required contracts are not available yet (${missing.join(', ')}), so the server will leave it suspended until an Event Pack provides them.';
      return DeskResult(
        true,
        'Installed ${manifest.id} ${manifest.version}. The server is stopped, so it is not running. It is marked to start the next time the server starts.$waiting',
      );
    }
    return DeskResult(
      true,
      'Installed ${manifest.id} ${manifest.version} and left it disabled. The server is stopped, so nothing is running.',
    );
  }

  Future<DeskResult> _enable(String id) async {
    final live = host;
    if (live != null) {
      try {
        final snapshot = await live.enable(id);
        if (snapshot.state == PluginState.suspended) {
          return DeskResult(
            true,
            'Enabled ${snapshot.id}. Suspended — ${snapshot.lastError ?? 'required Event Pack is missing.'}',
          );
        }
        if (snapshot.state != PluginState.active) {
          return DeskResult(
            false,
            'Enable of ${snapshot.id} finished in ${snapshot.state.name}. ${snapshot.lastError ?? ''}',
          );
        }
        return DeskResult(true, 'Enabled ${snapshot.id}. Active — running.');
      } on PluginHostException catch (error) {
        final snapshot = live.plugin(id);
        if (snapshot != null && snapshot.state != PluginState.active) {
          return DeskResult(
            false,
            'Enable of $id did not start the worker (${snapshot.state.name}). ${explainFailure(error)}',
          );
        }
        return DeskResult(false, explainFailure(error));
      }
    }
    final found = await _stored(id);
    if (found == null)
      return DeskResult(false, 'Package "$id" is not installed.');
    final blockers = compatibilityBlockers(found.manifest, await _context());
    if (blockers.isNotEmpty) return DeskResult(false, blockers.join(' '));
    final installed = await _readInstalled();
    final dependency = _dependencyProblem(
      found.manifest,
      installed,
      requireEnabled: true,
    );
    if (dependency != null) return DeskResult(false, dependency);
    await found.store.put(found.record.copyWith(enabled: true));
    return DeskResult(
      true,
      'Enabled $id. The server is stopped, so the package is not running. It will start when the server starts.',
    );
  }

  Future<DeskResult> _disable(String id, {required bool cascade}) async {
    final live = host;
    if (live != null) {
      final current = inventory.installedById(id);
      final affected = current == null
          ? const <String>[]
          : contractConsumers(inventory, current.manifest)
                .where((package) => package.state == PluginState.active)
                .map((package) => package.manifest.id)
                .toList();
      try {
        final snapshot = await live.disable(id, cascade: cascade);
        final extra = cascade && affected.isNotEmpty
            ? ' Suspended ${affected.join(', ')}.'
            : '';
        return DeskResult(
          true,
          'Disabled ${snapshot.id}. ${runtimeLabel(installed: true, serverRunning: true, enabled: snapshot.enabled, state: snapshot.state, error: snapshot.lastError)}$extra',
        );
      } on PluginHostException catch (error) {
        return DeskResult(false, explainFailure(error));
      }
    }
    final found = await _stored(id);
    if (found == null)
      return DeskResult(false, 'Package "$id" is not installed.');
    final installed = await _readInstalled();
    final dependents = packageDependents(Inventory(installed: installed), id)
        .where((package) => package.enabled)
        .map((package) => package.manifest.id)
        .toList();
    if (dependents.isNotEmpty) {
      return DeskResult(
        false,
        'Cannot disable "$id": required by ${dependents.join(', ')}. Disable those packages first.',
      );
    }
    if (found.manifest.isEventPack && !cascade) {
      final consumers =
          contractConsumers(Inventory(installed: installed), found.manifest)
              .where((package) => package.enabled)
              .map((package) => package.manifest.id)
              .toList();
      if (consumers.isNotEmpty) {
        return DeskResult(
          false,
          'Cannot disable "$id": ${consumers.join(', ')} still require its contracts. Confirm again to suspend them on the next start.',
        );
      }
    }
    await found.store.put(found.record.copyWith(enabled: false));
    return DeskResult(
      true,
      'Disabled $id. The server is stopped, so this only changes the saved state.',
    );
  }

  Future<DeskResult> _update(LibraryPackage package) async {
    final fresh = await _revalidate(package);
    if (fresh is DeskResult) return fresh;
    final opened = fresh as AyuPackage;
    try {
      final blockers = compatibilityBlockers(opened.manifest, await _context());
      if (blockers.isNotEmpty)
        return DeskResult(
          false,
          'Cannot update ${opened.manifest.id}. ${blockers.join(' ')}',
        );
      final live = host;
      if (live != null) {
        try {
          final snapshot = await live.update(opened.file);
          final rolled = snapshot.version != opened.manifest.version;
          if (rolled) {
            return DeskResult(
              false,
              'Update did not stay on ${opened.manifest.version}. Installed version is ${snapshot.version} (${snapshot.state.name}).',
            );
          }
          return DeskResult(
            snapshot.state != PluginState.failed &&
                snapshot.state != PluginState.crashed,
            'Updated ${snapshot.id} to ${snapshot.version}. ${runtimeLabel(installed: true, serverRunning: true, enabled: snapshot.enabled, state: snapshot.state, error: snapshot.lastError)}',
          );
        } on PluginHostException catch (error) {
          final snapshot = live.plugin(opened.manifest.id);
          final restored = snapshot == null
              ? ''
              : ' Installed version is now ${snapshot.version} (${snapshot.state.name}).';
          return DeskResult(false, '${explainFailure(error)}$restored');
        }
      }
      return await _updateStopped(opened);
    } finally {
      await opened.close();
    }
  }

  Future<DeskResult> _updateStopped(AyuPackage opened) async {
    final manifest = opened.manifest;
    final found = await _stored(manifest.id);
    if (found == null)
      return DeskResult(
        false,
        '${manifest.id} is not installed. Install it first.',
      );
    if (found.manifest.packageType != manifest.packageType) {
      return DeskResult(
        false,
        '${manifest.id} is installed as a ${found.manifest.packageType.wireName}; this file is a ${manifest.packageType.wireName}.',
      );
    }
    if (found.record.version == manifest.version) {
      return DeskResult(
        false,
        '${manifest.id} ${manifest.version} is already the installed version.',
      );
    }
    final installed = await _readInstalled();
    final rejecting = [
      for (final other in installed)
        for (final dependency in other.manifest.requiredDependencies)
          if (dependency.id == manifest.id &&
              !dependency.version.allows(manifest.version))
            other.manifest.id,
    ];
    if (rejecting.isNotEmpty) {
      return DeskResult(
        false,
        'Cannot update ${manifest.id} to ${manifest.version}: ${rejecting.join(', ')} do not accept that version.',
      );
    }
    final staging = await found.store.createStagingDirectory();
    try {
      await opened.extractTo(staging);
    } catch (error) {
      await found.store.discard(staging);
      return DeskResult(false, explainFailure(error));
    }
    try {
      await found.store.commit(
        staged: staging,
        id: manifest.id,
        version: manifest.version,
      );
    } on PackageException catch (error) {
      return DeskResult(false, explainFailure(error));
    }
    await found.store.put(found.record.copyWith(version: manifest.version));
    await _deleteVersion(found.store, manifest.id, found.record.version);
    final enabled = found.record.enabled;
    return DeskResult(
      true,
      'Updated ${manifest.id} from ${found.record.version} to ${manifest.version} on disk. '
      'The server is stopped, so this was not a hot update. '
      '${enabled ? 'The new version starts the next time the server starts.' : 'It stays disabled.'}',
    );
  }

  Future<DeskResult> _uninstall(String id, {required bool cascade}) async {
    final live = host;
    if (live != null) {
      try {
        await live.uninstall(id, cascade: cascade);
        return DeskResult(
          true,
          'Uninstalled $id. The library copy and the saved plugin data were kept.',
        );
      } on PluginHostException catch (error) {
        return DeskResult(false, explainFailure(error));
      }
    }
    final found = await _stored(id);
    if (found == null)
      return DeskResult(false, 'Package "$id" is not installed.');
    final installed = await _readInstalled();
    final dependents = packageDependents(
      Inventory(installed: installed),
      id,
    ).map((package) => package.manifest.id).toList();
    if (dependents.isNotEmpty) {
      return DeskResult(
        false,
        'Cannot uninstall "$id": required by ${dependents.join(', ')}.',
      );
    }
    if (found.manifest.isEventPack && !cascade) {
      final consumers =
          contractConsumers(Inventory(installed: installed), found.manifest)
              .where((package) => package.enabled)
              .map((package) => package.manifest.id)
              .toList();
      if (consumers.isNotEmpty) {
        return DeskResult(
          false,
          'Cannot uninstall "$id": ${consumers.join(', ')} require its contracts. Confirm the cascade uninstall.',
        );
      }
    }
    await found.store.remove(id);
    await _deleteVersion(found.store, id, found.record.version);
    return DeskResult(
      true,
      'Uninstalled $id from the server root. The original .ayu file and plugin data directory were kept.',
    );
  }

  Future<Object> _revalidate(LibraryPackage package) async {
    try {
      final opened = await AyuPackage.open(package.file);
      try {
        await opened.verifyArtifacts();
      } catch (error) {
        await opened.close();
        return DeskResult(false, explainFailure(error));
      }
      if (opened.manifest.id != package.manifest.id ||
          opened.manifest.version != package.manifest.version) {
        await opened.close();
        return DeskResult(
          false,
          'The file changed since the last refresh. Press R and choose it again.',
        );
      }
      return opened;
    } on PackageException catch (error) {
      return DeskResult(false, explainFailure(error));
    } on FileSystemException catch (error) {
      return DeskResult(false, error.message);
    }
  }

  DeskResult _installedMessage(PluginSnapshot snapshot) {
    final label = runtimeLabel(
      installed: true,
      serverRunning: true,
      enabled: snapshot.enabled,
      state: snapshot.state,
      error: snapshot.lastError,
    );
    final failed =
        snapshot.state == PluginState.failed ||
        snapshot.state == PluginState.crashed;
    return DeskResult(
      !failed,
      'Installed ${snapshot.id} ${snapshot.version}. $label',
    );
  }

  String? _dependencyProblem(
    PluginManifest manifest,
    List<InstalledPackage> installed, {
    required bool requireEnabled,
  }) {
    final problems = <String>[];
    for (final dependency in manifest.dependencies) {
      InstalledPackage? found;
      for (final package in installed) {
        if (package.manifest.id == dependency.id) found = package;
      }
      if (found == null) {
        if (!dependency.optional)
          problems.add(
            '"${dependency.id}" ${dependency.version} is not installed',
          );
        continue;
      }
      if (!dependency.version.allows(found.manifest.version)) {
        if (!dependency.optional) {
          problems.add(
            '"${dependency.id}" ${found.manifest.version} is installed but ${dependency.version} is required',
          );
        }
        continue;
      }
      if (requireEnabled &&
          !dependency.optional &&
          !found.enabled &&
          found.state != PluginState.active) {
        problems.add(
          '"${dependency.id}" is disabled; enable it first, or install without enabling',
        );
      }
    }
    if (problems.isEmpty) return null;
    return 'Cannot install ${manifest.id}. ${problems.join(' ')}';
  }

  List<String> _missingContracts(
    PluginManifest manifest,
    List<InstalledPackage> installed,
  ) {
    final missing = <String>[];
    for (final requirement in manifest.requiredEvents) {
      final provider = installed.where(
        (package) =>
            package.manifest.isEventPack &&
            package.enabled &&
            package.manifest.provides.any(
              (contract) =>
                  contract.id == requirement.id &&
                  requirement.version.allows(contract.version),
            ),
      );
      if (provider.isEmpty) missing.add(requirement.id);
    }
    return missing;
  }

  Future<_Stored?> _stored(String id) async {
    final layout = ServerLayout(control.root);
    for (final root in [layout.plugins.root, layout.events.root]) {
      final state = File(p.join(root.path, 'state.json'));
      if (!await state.exists()) continue;
      final store = PluginStore(root, log: _log);
      await store.open();
      final record = store.records[id];
      if (record == null) continue;
      final stored = await store.loadInstalled();
      for (final item in stored) {
        if (item.record.id == id) {
          return _Stored(store, item.record, item.manifest);
        }
      }
    }
    return null;
  }

  Future<void> _deleteVersion(
    PluginStore store,
    String id,
    Version version,
  ) async {
    final target = p.normalize(
      store.layout.installDirectory(id, version).absolute.path,
    );
    final root = p.normalize(store.layout.installed.absolute.path);
    if (!p.isWithin(root, target)) {
      throw StateError('refusing to delete $target outside $root');
    }
    await store.deleteInstalled(id, version);
  }
}

final class _Stored {
  const _Stored(this.store, this.record, this.manifest);

  final PluginStore store;
  final InstalledPluginRecord record;
  final PluginManifest manifest;
}
