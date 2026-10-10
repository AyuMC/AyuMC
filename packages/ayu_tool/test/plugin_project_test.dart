import 'dart:io';

import 'package:ayu_tool/ayu_tool.dart';
import 'package:ayu_tool/src/tool_exception.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(
    () async => temp = await Directory.systemTemp.createTemp('ayu_tool_test_'),
  );
  tearDown(() => temp.delete(recursive: true));

  Future<Directory> project(
    String descriptor, {
    String pubspecVersion = '2.3.4',
    bool entry = true,
  }) async {
    File(
      p.join(temp.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: demo\nversion: $pubspecVersion\n');
    File(
      p.join(temp.path, PluginProject.descriptorFileName),
    ).writeAsStringSync(descriptor);
    if (entry) {
      File(p.join(temp.path, 'bin', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');
    }
    return temp;
  }

  test('loads a descriptor and inherits the version from pubspec', () async {
    final loaded = await PluginProject.load(
      await project('''
id: demo
name: Demo
api: "^1.0.0"
capabilities: [commands]
dependencies:
  permissions: ">=1.0.0 <2.0.0"
'''),
    );
    expect(loaded.id, 'demo');
    expect(loaded.version, Version(2, 3, 4));
    expect(loaded.entry, 'bin/main.dart');
    expect(loaded.capabilities, {'commands'});
    expect(loaded.dependencies.single.id, 'permissions');
    expect(loaded.dependencies.single.version.allows(Version(1, 5, 0)), isTrue);
  });

  test('the example plugin project in the repository is valid', () async {
    final loaded = await PluginProject.load(
      Directory(p.join('..', '..', 'examples', 'example_plugin')),
    );
    expect(loaded.id, 'example_plugin');
    expect(loaded.capabilities, {'commands', 'events', 'config'});
    expect(loaded.configDirectory, 'config');
    expect(loaded.assetDirectories, ['assets']);
  });

  test('collects every problem', () async {
    await expectLater(
      PluginProject.load(
        await project('''
id: Bad Id
api: nope
version: one
assets: [missing]
''', entry: false),
      ),
      throwsA(
        isA<ToolException>().having(
          (e) => e.details.join('\n'),
          'details',
          allOf(
            contains('id:'),
            contains('name:'),
            contains('api:'),
            contains('version:'),
            contains('entry:'),
            contains('assets:'),
          ),
        ),
      ),
    );
  });

  test('a directory without a descriptor is reported', () async {
    await expectLater(
      PluginProject.load(temp),
      throwsA(
        isA<ToolException>().having(
          (e) => e.message,
          'message',
          contains(PluginProject.descriptorFileName),
        ),
      ),
    );
  });
}
