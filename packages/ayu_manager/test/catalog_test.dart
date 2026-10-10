import 'dart:convert';
import 'dart:io';

import 'package:ayu_manager/ayu_manager.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late Directory repo;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ayu-catalog-');
    repo = Directory(p.join(root.path, 'repo'));
    await repo.create();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'discovers plugins and event packs and keeps a bad archive from hiding the rest',
    () async {
      final pluginDir = Directory(
        p.join(repo.path, 'examples', 'alpha', 'build', 'ayu'),
      );
      final packDir = Directory(
        p.join(repo.path, 'event_packs_src', 'packs', 'build', 'ayu'),
      );
      await writePackage(pluginDir, id: 'alpha');
      await writePackage(
        packDir,
        id: 'packs',
        type: PackageType.eventPack,
        profiles: const ['AyuMC-1.8.9-release'],
        provides: [sampleContract('sample.happened')],
        capabilities: const {'observe', 'publish'},
      );
      await Directory(
        p.join(repo.path, 'examples', 'alpha', '.dart_tool'),
      ).create(recursive: true);
      await File(
        p.join(repo.path, 'examples', 'alpha', '.dart_tool', 'hidden.ayu'),
      ).writeAsString('nope');
      await Directory(
        p.join(root.path, 'plugins', 'installed', 'sneak'),
      ).create(recursive: true);
      await File(
        p.join(root.path, 'plugins', 'installed', 'sneak', 'sneak.ayu'),
      ).writeAsString('installed-tree');
      final library = Directory(p.join(root.path, 'library'));
      await library.create(recursive: true);
      await File(p.join(library.path, 'broken.ayu')).writeAsString('not a zip');

      final scanner = PackageScanner(serverRoot: root, repositoryRoot: repo);
      final previous = Directory.current;
      Directory.current = Directory.systemTemp.path;
      late final ({
        List<LibraryPackage> packages,
        List<DiscoveryFailure> failures,
        List<String> roots,
      })
      found;
      try {
        found = await scanner.scan(
          ScanContext(
            profileId: 'AyuMC-1.8.9-release',
            apiVersion: Version.parse('1.0.0'),
            target: RuntimeTarget.current(),
          ),
        );
      } finally {
        Directory.current = previous.path;
      }

      final ids = found.packages.map((package) => package.manifest.id).toList();
      expect(ids, containsAll(['alpha', 'packs']));
      expect(
        found.packages
            .singleWhere((package) => package.manifest.id == 'packs')
            .manifest
            .isEventPack,
        isTrue,
      );
      expect(
        found.packages
            .singleWhere((package) => package.manifest.id == 'alpha')
            .manifest
            .isEventPack,
        isFalse,
      );
      expect(ids, isNot(contains('hidden')));
      expect(ids, isNot(contains('sneak')));
      expect(
        found.failures.map((failure) => failure.path).join('\n'),
        contains('broken.ayu'),
      );
      expect(found.packages, isNotEmpty);
    },
  );

  test(
    'shows distinct versions and does not list the installed version again as available',
    () async {
      final library = Directory(p.join(root.path, 'library', 'one'));
      final other = Directory(p.join(root.path, 'library', 'two'));
      final first = await writePackage(library, id: 'alpha', version: '1.0.0');
      final second = await writePackage(other, id: 'alpha', version: '1.1.0');
      await writePackage(
        Directory(p.join(root.path, 'library', 'copy')),
        id: 'alpha',
        version: '1.0.0',
        fileName: 'alpha-copy.ayu',
      );

      final desk = PackageDesk(
        control: ServerControl(root: root),
        repositoryRoot: repo,
      );
      final refreshed = await desk.refresh();
      expect(refreshed.ok, isTrue, reason: refreshed.message);
      expect(refreshed.message, contains('Found'));
      expect(desk.inventory.installed, isEmpty);
      expect(
        desk.inventory.library.where(
          (package) => package.manifest.version.toString() == '1.0.0',
        ),
        hasLength(2),
      );
      expect(
        desk.inventory.library.any(
          (package) => package.warnings.any(
            (warning) => warning.contains('Several archives'),
          ),
        ),
        isTrue,
      );

      final install = await desk.install(
        desk.inventory.library.firstWhere(
          (package) =>
              p.equals(p.normalize(package.file.path), p.normalize(first.path)),
        ),
        enable: false,
      );
      expect(install.ok, isTrue, reason: install.message);
      expect(install.message, contains('nothing is running'));
      final rows = buildCatalogRows(
        events: false,
        inventory: desk.inventory,
        filter: '',
      );
      final alphaRows = rows
          .where((row) => row.selectable && row.title == 'alpha')
          .toList();
      expect(
        alphaRows.map((row) => row.subtitle),
        containsAll(['1.0.0', '1.1.0']),
      );
      expect(
        alphaRows.where((row) => row.badge == 'Available — not installed.'),
        isEmpty,
      );
      expect(
        alphaRows.where((row) => row.badge == 'Update available.'),
        isNotEmpty,
      );
      expect(second.existsSync(), isTrue);
      expect(first.existsSync(), isTrue);
    },
  );

  test(
    'a configured path inside the install tree is rejected and other packages remain',
    () async {
      await Directory(p.join(root.path, 'config')).create(recursive: true);
      await File(
        p.join(root.path, 'config', 'package-libraries.json'),
      ).writeAsString(
        jsonEncode({
          'directories': [p.join(root.path, 'plugins')],
        }),
      );
      await Directory(p.join(root.path, 'plugins')).create();
      await writePackage(Directory(p.join(root.path, 'plugins')), id: 'sneak');
      await writePackage(Directory(p.join(root.path, 'library')), id: 'kept');

      final found = await PackageScanner(serverRoot: root, repositoryRoot: repo)
          .scan(
            ScanContext(
              profileId: 'AyuMC-1.8.9-release',
              apiVersion: Version.parse('1.0.0'),
              target: RuntimeTarget.current(),
            ),
          );
      expect(found.packages.map((package) => package.manifest.id), ['kept']);
      expect(found.failures.single.message, contains('installed'));
    },
  );

  test(
    'package screen renders available and installed rows, filters, and cancels a confirm',
    () {
      final session = ManagerSession(control: ServerControl(root: root));
      session.desk.inventory = Inventory(
        library: [
          LibraryPackage(
            file: File(p.join(root.path, 'alpha.ayu')),
            manifest: _manifest('alpha'),
          ),
          LibraryPackage(
            file: File(p.join(root.path, 'audit.ayu')),
            manifest: _manifest('audit'),
          ),
        ],
        roots: [p.join(root.path, 'library')],
      );
      session.section = ManagerSection.plugins;
      final listed = session.render(color: false);
      expect(listed, contains('alpha'));
      expect(listed, contains('audit'));
      expect(listed, contains('Available — not installed.'));
      expect('AYUMC'.allMatches(listed), hasLength(1));

      session.apply(const KeyEvent.text('/'));
      session.apply(const KeyEvent.text('a'));
      session.apply(const KeyEvent.text('u'));
      session.apply(const KeyEvent.text('d'));
      final filtered = session.render(color: false);
      expect(filtered, contains('audit'));
      expect(filtered, isNot(contains('alpha')));

      session.apply(const KeyEvent.nav(ManagerKey.escape));
      session.apply(const KeyEvent.nav(ManagerKey.up));
      session.apply(const KeyEvent.text('a'));
      expect(session.pluginScreen.confirming, isTrue);
      expect(session.render(color: false), contains('Install alpha'));
      final cancelled = session.apply(const KeyEvent.text('n'));
      expect(cancelled, isA<CatalogCommand>());
      expect(cancelled!.message, 'Cancelled.');
      expect(session.pluginScreen.confirming, isFalse);

      session.apply(const KeyEvent.text('a'));
      final accepted = session.apply(const KeyEvent.text('y'));
      expect(accepted!.action, CatalogAction.install);
      expect(accepted.enable, isTrue);
      expect(accepted.archivePath, endsWith('alpha.ayu'));
    },
  );

  test('an empty event screen explains where packages are read', () {
    final session = ManagerSession(control: ServerControl(root: root));
    session.apply(const KeyEvent.nav(ManagerKey.f3));
    final text = session.render(color: false);
    expect(text, contains('No event packs installed'));
    expect(text, contains('library'));
    expect(screenFrame, '\x1b[H\x1b[J');
    expect('AYUMC'.allMatches(text), hasLength(1));
  });

  test(
    'status phrases distinguish stopped, active, suspended, failed, and crashed',
    () {
      expect(
        runtimeLabel(installed: true, serverRunning: false, enabled: true),
        contains('Not running now'),
      );
      expect(
        runtimeLabel(
          installed: true,
          serverRunning: true,
          enabled: true,
          state: PluginState.active,
        ),
        'Active — running.',
      );
      expect(
        runtimeLabel(
          installed: true,
          serverRunning: true,
          enabled: true,
          state: PluginState.suspended,
        ),
        contains('Suspended'),
      );
      expect(
        runtimeLabel(
          installed: true,
          serverRunning: true,
          enabled: true,
          state: PluginState.failed,
          error: 'boom',
        ),
        contains('boom'),
      );
      expect(
        runtimeLabel(
          installed: true,
          serverRunning: true,
          enabled: true,
          state: PluginState.crashed,
        ),
        contains('Crashed'),
      );
      expect(
        runtimeLabel(installed: false, serverRunning: true, enabled: false),
        'Available — not installed.',
      );
    },
  );

  test('detail text names contracts and the plugins that require them', () {
    final pack = InstalledPackage(
      manifest: PluginManifest(
        id: 'session_events',
        name: 'Session Events',
        version: Version.parse('1.0.0'),
        api: VersionConstraint.parse('^1.0.0'),
        packageType: PackageType.eventPack,
        profiles: const ['AyuMC-1.8.9-release'],
        provides: [sampleContract('session.joined')],
      ),
      enabled: true,
      state: PluginState.active,
      installDirectory: p.join(root.path, 'events'),
      dataDirectory: p.join(root.path, 'events', 'data'),
    );
    final audit = InstalledPackage(
      manifest: PluginManifest(
        id: 'session_audit',
        name: 'Session Audit',
        version: Version.parse('1.0.0'),
        api: VersionConstraint.parse('^1.0.0'),
        events: [
          ContractRequirement(
            id: 'session.joined',
            version: VersionConstraint.parse('^1.0.0'),
          ),
        ],
      ),
      enabled: true,
      state: PluginState.active,
      installDirectory: p.join(root.path, 'plugins'),
      dataDirectory: p.join(root.path, 'plugins', 'data'),
    );
    final lines = describeSelection(
      inventory: Inventory(installed: [pack, audit], serverRunning: true),
      installed: pack,
    );
    expect(lines.join('\n'), contains('session.joined'));
    expect(lines.join('\n'), contains('session_audit'));
    expect(lines.join('\n'), contains('requires'));
  });
}

PluginManifest _manifest(String id) => PluginManifest(
  id: id,
  name: 'Package $id',
  version: Version.parse('1.0.0'),
  api: VersionConstraint.parse('^1.0.0'),
);
