import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

Map<String, Object?> base({String type = 'plugin'}) => {
  'formatVersion': 1,
  'packageType': type,
  'id': 'demo',
  'name': 'Demo',
  'version': '1.0.0',
  'api': '^1.0.0',
  'artifacts': {
    'windows-x64': {'path': 'bin/windows-x64/plugin.aot', 'sha256': 'a' * 64, 'size': 10, 'dartSdk': '3.13.4'},
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
  test('packageType defaults to plugin and round-trips', () {
    final manifest = PluginManifest.fromJson(base()..remove('packageType'));
    expect(manifest.packageType, PackageType.plugin);
    expect(manifest.isEventPack, isFalse);
    expect(PluginManifest.parse(manifest.toJsonString()).packageType, PackageType.plugin);
    expect(problemsOf(base(type: 'mod')).single, contains('packageType'));
  });

  test('a valid event pack declares profiles and contracts', () {
    final manifest = PluginManifest.fromJson(base(type: 'event-pack')
      ..['profiles'] = ['AyuMC-1.8.9-release']
      ..['capabilities'] = ['observe', 'publish']
      ..['provides'] = [
        {
          'id': 'player.joined',
          'version': '1.0.0',
          'sources': ['core.session.joined'],
          'schema': {'player': 'string', 'uuid': 'string'},
        },
        {
          'id': 'player.login',
          'version': '1.0.0',
          'delivery': {'mode': 'decision', 'onTimeout': 'deny', 'budgetMs': 150},
          'sources': ['core.session.login'],
        },
        {
          'id': 'player.movement',
          'version': '2.1.0',
          'delivery': {'overflow': 'coalesce', 'coalesceKey': 'player', 'queueLimit': 64},
          'sources': ['core.packet.inbound'],
        },
      ]);
    expect(manifest.isEventPack, isTrue);
    expect(manifest.supportsProfile('AyuMC-1.8.9-release'), isTrue);
    expect(manifest.supportsProfile('AyuMC-1.12-release'), isFalse);
    expect(manifest.provides.map((c) => c.id), ['player.joined', 'player.login', 'player.movement']);
    expect(manifest.provides[1].delivery.mode, DeliveryMode.decision);
    expect(manifest.provides[1].delivery.onTimeout, TimeoutPolicy.deny);
    expect(manifest.provides[1].delivery.budget, const Duration(milliseconds: 150));
    expect(manifest.provides[2].delivery.overflow, OverflowPolicy.coalesce);
    expect(manifest.provides[2].delivery.coalesceKey, 'player');
    expect(manifest.provides[2].version, Version(2, 1, 0));
    expect(manifest.primitiveSources, {'core.session.joined', 'core.session.login', 'core.packet.inbound'});
    final copy = PluginManifest.parse(manifest.toJsonString());
    expect(copy.toJson(), manifest.toJson());
  });

  test('event packs must name profiles and provide contracts', () {
    final problems = problemsOf(base(type: 'event-pack'));
    expect(problems.join('\n'), allOf(contains('profiles'), contains('provide at least one')));
  });

  test('contract declarations are validated', () {
    final problems = problemsOf(base(type: 'event-pack')
      ..['profiles'] = ['AyuMC-1.8.9-release']
      ..['provides'] = [
        {'id': 'Player', 'version': '1.0.0'},
        {'id': 'core.session.opened', 'version': '1.0.0'},
        {'id': 'a.b', 'version': 'x'},
        {'id': 'a.c', 'version': '1.0.0', 'delivery': {'overflow': 'coalesce'}},
        {'id': 'a.c', 'version': '1.0.0'},
        {'id': 'a.d', 'version': '1.0.0', 'sources': ['session.joined'], 'schema': {'x': 'blob'}},
      ]);
    final text = problems.join('\n');
    expect(text, contains('provides[0].id'));
    expect(text, contains('provides[1].id'));
    expect(text, contains('provides[2].version'));
    expect(text, contains('coalesceKey'));
    expect(text, contains('declared more than once'));
    expect(text, contains('not an internal primitive'));
    expect(text, contains('unknown type "blob"'));
  });

  test('plugins declare required and optional contracts', () {
    final manifest = PluginManifest.fromJson(base()
      ..['capabilities'] = ['events']
      ..['events'] = {
        'requires': [{'id': 'player.joined', 'version': '^1.0.0'}],
        'optional': [{'id': 'player.disconnected', 'version': '>=1.0.0 <3.0.0'}],
      });
    expect(manifest.requiredEvents.single.id, 'player.joined');
    expect(manifest.optionalEvents.single.version.allows(Version(2, 5, 0)), isTrue);
    expect(PluginManifest.parse(manifest.toJsonString()).events.length, 2);
  });

  test('plugins cannot provide contracts or hold event-pack capabilities', () {
    final problems = problemsOf(base()
      ..['capabilities'] = ['observe', 'publish', 'events']
      ..['provides'] = [{'id': 'a.b', 'version': '1.0.0'}]
      ..['events'] = {'requires': [{'id': 'a.b', 'version': '^1.0.0'}, {'id': 'a.b', 'version': '^1.0.0'}], 'extra': []});
    final text = problems.join('\n');
    expect(text, contains('"observe" is reserved'));
    expect(text, contains('"publish" is reserved'));
    expect(text, contains('only event packs provide'));
    expect(text, contains('listed more than once'));
    expect(text, contains('events.extra'));
  });

  test('event packs cannot consume contracts', () {
    final problems = problemsOf(base(type: 'event-pack')
      ..['profiles'] = ['p']
      ..['provides'] = [{'id': 'a.b', 'version': '1.0.0'}]
      ..['events'] = {'requires': []});
    expect(problems.single, contains('do not consume'));
  });
}
