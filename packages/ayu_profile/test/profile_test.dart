import 'dart:io';

import 'package:ayu_profile/ayu_profile.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('ayu_profile_test_'));
  tearDown(() => temp.delete(recursive: true));

  test('the catalog ships the 1.8.9 release profile', () {
    expect(ProfileCatalog.release189.id, 'AyuMC-1.8.9-release');
    expect(ProfileCatalog.release189.protocolVersion, 47);
    expect(ProfileCatalog.byId('AyuMC-1.8.9-release'), ProfileCatalog.release189);
    expect(ProfileCatalog.byId('nope'), isNull);
  });

  test('selection defaults, persists and preserves other keys', () async {
    final file = File('${temp.path}/config/server.json');
    final selection = ProfileSelection(file);
    expect(await selection.load(), ProfileCatalog.defaultProfile);

    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{"port": 25565}');
    await selection.save(ProfileCatalog.release189);
    expect(await selection.load(), ProfileCatalog.release189);
    expect(file.readAsStringSync(), contains('"port": 25565'));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('unknown or malformed selections are reported', () async {
    final file = File('${temp.path}/server.json')..writeAsStringSync('{"profile": "AyuMC-9.9-release"}');
    await expectLater(ProfileSelection(file).load(),
        throwsA(isA<ProfileException>().having((e) => e.message, 'message', contains('available'))));
    file.writeAsStringSync('{');
    await expectLater(ProfileSelection(file).load(), throwsA(isA<ProfileException>()));
  });
}
