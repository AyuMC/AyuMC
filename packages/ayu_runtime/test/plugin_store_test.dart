import 'dart:io';

import 'package:ayu_package/ayu_package.dart';
import 'package:ayu_runtime/src/plugin_store.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('ayu_store_test_'));
  tearDown(() => temp.delete(recursive: true));

  test('open creates the layout and purges interrupted staging', () async {
    final layout = PluginStoreLayout(temp);
    final leftover = Directory(p.join(layout.staging.path, 'old'))..createSync(recursive: true);
    File(p.join(leftover.path, 'x')).writeAsStringSync('x');

    final store = PluginStore(temp, log: testLogger);
    await store.open();
    expect(layout.installed.existsSync(), isTrue);
    expect(layout.data.existsSync(), isTrue);
    expect(leftover.existsSync(), isFalse);
    expect(store.records, isEmpty);
  });

  test('state round-trips through the file and is written atomically', () async {
    final store = PluginStore(temp, log: testLogger);
    await store.open();
    await store.put(InstalledPluginRecord(id: 'a', version: Version(1, 2, 3), enabled: true));
    await store.put(InstalledPluginRecord(id: 'b', version: Version(2, 0, 0), enabled: false));
    expect(File('${store.layout.stateFile.path}.tmp').existsSync(), isFalse);

    final reopened = PluginStore(temp, log: testLogger);
    await reopened.open();
    expect(reopened.records['a']?.version, Version(1, 2, 3));
    expect(reopened.records['a']?.enabled, isTrue);
    expect(reopened.records['b']?.enabled, isFalse);
    await reopened.remove('a');
    final again = PluginStore(temp, log: testLogger);
    await again.open();
    expect(again.records.keys, ['b']);
  });

  test('a corrupt state file is set aside instead of crashing', () async {
    final layout = PluginStoreLayout(temp);
    layout.root.createSync(recursive: true);
    layout.stateFile.writeAsStringSync('{not json');
    final store = PluginStore(temp, log: testLogger);
    await store.open();
    expect(store.records, isEmpty);
    expect(File('${layout.stateFile.path}.corrupt').existsSync(), isTrue);
  });

  test('commit moves staging into place and refuses collisions', () async {
    final store = PluginStore(temp, log: testLogger);
    await store.open();
    final staged = await store.createStagingDirectory();
    File(p.join(staged.path, 'manifest.json')).writeAsStringSync('{}');
    final installed = await store.commit(staged: staged, id: 'a', version: Version(1, 0, 0));
    expect(installed.path, store.layout.installDirectory('a', Version(1, 0, 0)).path);
    expect(File(p.join(installed.path, 'manifest.json')).existsSync(), isTrue);
    expect(staged.existsSync(), isFalse);

    final second = await store.createStagingDirectory();
    await expectLater(
      store.commit(staged: second, id: 'a', version: Version(1, 0, 0)),
      throwsA(isA<PackageException>().having((e) => e.code, 'code', PackageErrorCode.destinationNotEmpty)),
    );
    expect(second.existsSync(), isFalse, reason: 'rejected staging is discarded');
  });

  test('loadInstalled drops records whose files vanished', () async {
    final store = PluginStore(temp, log: testLogger);
    await store.open();
    await store.put(InstalledPluginRecord(id: 'ghost', version: Version(1, 0, 0), enabled: true));
    expect(await store.loadInstalled(), isEmpty);
    expect(store.records, isEmpty);
  });

  test('deleteInstalled removes the version and the empty plugin directory but keeps data', () async {
    final store = PluginStore(temp, log: testLogger);
    await store.open();
    final staged = await store.createStagingDirectory();
    await store.commit(staged: staged, id: 'a', version: Version(1, 0, 0));
    final data = store.layout.dataDirectory('a')..createSync(recursive: true);
    await store.deleteInstalled('a', Version(1, 0, 0));
    expect(store.layout.pluginDirectory('a').existsSync(), isFalse);
    expect(data.existsSync(), isTrue);
  });
}
