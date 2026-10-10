import 'dart:convert';

import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

Map<String, Object?> validManifest() => {
  'formatVersion': 1,
  'id': 'example_plugin',
  'name': 'Example Plugin',
  'version': '1.2.3',
  'api': '>=1.0.0 <2.0.0',
  'entryPoint': 'src/bin/main.dart',
  'artifacts': {
    'windows-x64': {
      'path': 'bin/windows-x64/plugin.aot',
      'sha256': 'a' * 64,
      'size': 1024,
      'dartSdk': '3.13.4',
    },
  },
  'dependencies': [
    {'id': 'permissions', 'version': '^1.0.0'},
    {'id': 'economy', 'version': '>=2.0.0 <3.0.0', 'optional': true},
  ],
  'capabilities': ['commands', 'events'],
  'build': {
    'tool': 'ayu',
    'toolVersion': '0.1.0',
    'dartSdk': '3.13.4',
    'createdAt': '2026-10-10T12:00:00Z',
  },
};

List<String> problemsOf(Map<String, Object?> json) {
  try {
    PluginManifest.fromJson(json);
    return const [];
  } on PackageException catch (e) {
    expect(e.code, PackageErrorCode.manifestInvalid);
    return e.problems;
  }
}

void main() {
  test('parses a complete manifest', () {
    final manifest = PluginManifest.fromJson(validManifest());
    expect(manifest.id, 'example_plugin');
    expect(manifest.version, Version(1, 2, 3));
    expect(manifest.api.allows(Version(1, 5, 0)), isTrue);
    expect(manifest.api.allows(Version(2, 0, 0)), isFalse);
    expect(manifest.artifactFor(const RuntimeTarget(TargetOs.windows, TargetArch.x64))?.size, 1024);
    expect(manifest.artifactFor(const RuntimeTarget(TargetOs.linux, TargetArch.x64)), isNull);
    expect(manifest.requiredDependencies.map((d) => d.id), ['permissions']);
    expect(manifest.capabilities, {'commands', 'events'});
    expect(manifest.build?.createdAt.isUtc, isTrue);
  });

  test('round-trips through JSON', () {
    final original = PluginManifest.fromJson(validManifest());
    final copy = PluginManifest.parse(original.toJsonString());
    expect(copy.toJson(), original.toJson());
    expect(jsonDecode(copy.toJsonString()), jsonDecode(original.toJsonString()));
  });

  test('reports every problem at once', () {
    final json = validManifest()
      ..['id'] = 'Bad Id'
      ..['version'] = 'one'
      ..['api'] = 'nope'
      ..remove('name');
    final problems = problemsOf(json);
    expect(problems, hasLength(4));
    expect(problems.join('\n'), allOf(contains('id:'), contains('version:'), contains('api:'), contains('name:')));
  });

  test('rejects unsupported format versions', () {
    expect(problemsOf(validManifest()..['formatVersion'] = 99).single, contains('formatVersion'));
    expect(problemsOf(validManifest()..remove('formatVersion')).single, contains('formatVersion'));
  });

  test('rejects malformed artifacts', () {
    final json = validManifest()
      ..['artifacts'] = {
        'windows-x64': {'path': '../plugin.aot', 'sha256': 'zz', 'size': 0, 'dartSdk': 'x'},
        'amiga-m68k': {'path': 'bin/a', 'sha256': 'a' * 64, 'size': 1, 'dartSdk': '3.0.0'},
      };
    final problems = problemsOf(json);
    expect(problems.join('\n'), allOf(
      contains('artifacts.windows-x64.path'),
      contains('artifacts.windows-x64.sha256'),
      contains('artifacts.windows-x64.size'),
      contains('artifacts.windows-x64.dartSdk'),
      contains('artifacts.amiga-m68k'),
    ));
  });

  test('rejects duplicate, self and malformed dependencies', () {
    final json = validManifest()
      ..['dependencies'] = [
        {'id': 'example_plugin', 'version': '^1.0.0'},
        {'id': 'economy', 'version': '^1.0.0'},
        {'id': 'economy', 'version': '^1.0.0'},
        {'id': 'ok', 'version': 'not a range'},
      ];
    final problems = problemsOf(json);
    expect(problems.join('\n'), allOf(contains('depend on itself'), contains('more than once'), contains('not a version constraint')));
  });

  test('rejects unknown capabilities', () {
    expect(problemsOf(validManifest()..['capabilities'] = ['commands', 'network']).single, contains('network'));
  });

  test('rejects invalid JSON', () {
    expect(() => PluginManifest.parse('{'), throwsA(isA<PackageException>()
        .having((e) => e.code, 'code', PackageErrorCode.manifestInvalid)));
    expect(() => PluginManifest.parse('[]'), throwsA(isA<PackageException>()));
  });

  group('describeUnsafeArchivePath', () {
    const limits = PackageLimits();

    test('accepts ordinary relative paths', () {
      for (final path in ['manifest.json', 'src/lib/a.dart', 'bin/windows-x64/plugin.aot', 'assets/dir/']) {
        expect(PluginManifest.describeUnsafeArchivePath(path, limits), isNull, reason: path);
      }
    });

    test('rejects traversal, absolute, drive and device names', () {
      for (final path in ['../x', 'a/../b', '/etc/passwd', r'C:\x', 'a\\b', 'a//b', './a', 'CON', 'dir/nul.txt', 'a:b', 'trailing.', 'a\u0000b']) {
        expect(PluginManifest.describeUnsafeArchivePath(path, limits), isNotNull, reason: path);
      }
    });

    test('enforces depth and length limits', () {
      expect(PluginManifest.describeUnsafeArchivePath(List.filled(40, 'd').join('/'), limits), contains('deeper'));
      expect(PluginManifest.describeUnsafeArchivePath('x' * 600, limits), contains('longer'));
    });
  });

  group('RuntimeTarget', () {
    test('parses ids and Dart version banners', () {
      expect(RuntimeTarget.tryParse('linux-x64')?.os, TargetOs.linux);
      expect(RuntimeTarget.tryParse('linux'), isNull);
      expect(RuntimeTarget.tryParse('beos-x64'), isNull);
      expect(
        RuntimeTarget.parseDartVersionBanner('Dart SDK version: 3.13.4 (stable) (Tue Sep 15 01:01:15 2026 -0700) on "windows_x64"'),
        const RuntimeTarget(TargetOs.windows, TargetArch.x64),
      );
      expect(RuntimeTarget.current().id, isIn(['windows-x64', 'linux-x64', 'macos-x64', 'macos-arm64', 'linux-arm64', 'windows-arm64']));
    });
  });
}
