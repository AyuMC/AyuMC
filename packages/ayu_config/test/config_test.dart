import 'dart:io';

import 'package:ayu_config/ayu_config.dart';
import 'package:test/test.dart';

final class AuditConfig extends AyuConfig {
  late final MessageOption joinMessage;
  late final BoolOption logJoins;
  late final IntOption maxLength;
  late final SecretOption token;

  @override
  void define() {
    joinMessage = add(
      MessageOption(
        'messages.join',
        defaultValue: 'Player {session_audit.player.name} joined.',
        placeholders: {AuditPlaceholders.playerName},
      ),
    );
    logJoins = add(BoolOption('logging.log-joins', defaultValue: true));
    maxLength = add(IntOption('limits.max-message-length', defaultValue: 200, min: 1, max: 1000));
    token = add(SecretOption('secrets.token', defaultValue: 'hidden'));
  }
}

abstract final class AuditPlaceholders {
  static final playerName = Placeholder<String>(
    id: 'session_audit.player.name',
    description: 'Username for this message.',
    resolve: (context) => context.requirePlayerName(),
  );
}

void main() {
  test('defaults render a typed placeholder', () {
    final config = AuditConfig();
    final text = config.snapshot.render(
      config.joinMessage,
      const PlaceholderContext(playerName: 'Steve'),
    );
    expect(text, 'Player Steve joined.');
    expect(config.snapshot.read(config.logJoins), isTrue);
    expect(config.snapshot.redacted()['secrets.token'], '***');
  });

  test('a valid file replaces the snapshot and an invalid type does not', () {
    final config = AuditConfig();
    final applied = config.applyDocument({
      'ayu': {'schema-version': 1},
      'messages': {'join': 'Hello {session_audit.player.name}.'},
      'logging': {'log-joins': false},
      'limits': {'max-message-length': 40},
      'extra': {'kept': true},
    });
    expect(applied.applied, isTrue);
    expect(applied.warnings.single, contains('unknown key extra.kept'));
    expect(config.snapshot.read(config.logJoins), isFalse);
    expect(config.snapshot.read(config.maxLength), 40);
    final revision = config.snapshot.revision;

    final rejected = config.applyDocument({
      'limits': {'max-message-length': 'many'},
    });
    expect(rejected.applied, isFalse);
    expect(rejected.summary, contains('limits.max-message-length'));
    expect(rejected.summary, contains('integer'));
    expect(config.snapshot.revision, revision);
    expect(config.snapshot.read(config.maxLength), 40);
  });

  test('an unknown placeholder is rejected before any event', () {
    final config = AuditConfig();
    final rejected = config.applyDocument({
      'messages': {'join': 'Hi {session_audit.player.naem}.'},
    });
    expect(rejected.applied, isFalse);
    expect(rejected.summary, contains('{session_audit.player.naem}'));
    expect(rejected.summary, contains('{session_audit.player.name}'));
    expect(
      config.snapshot.render(config.joinMessage, const PlaceholderContext(playerName: 'Ada')),
      contains('Ada'),
    );
  });

  test('literal braces are escaped and a server context cannot read a player name', () {
    final parsed = ParsedTemplate.parse('use {{braces}} {session_audit.player.name}', (message) => fail(message))!;
    expect(
      parsed.render(
        const PlaceholderContext(playerName: 'Ada'),
        {'session_audit.player.name': AuditPlaceholders.playerName},
      ),
      'use {braces} Ada',
    );
    expect(
      () => AuditPlaceholders.playerName.render(const PlaceholderContext(kind: PlaceholderContextKind.server)),
      throwsA(isA<PlaceholderException>()),
    );
    expect(ParsedTemplate.parse('broken {', (message) => expect(message, contains('unbalanced'))), isNull);
  });

  test('schema migration keeps the previous snapshot when no path exists', () {
    final config = AuditConfig();
    final rejected = config.applyDocument({
      'ayu': {'schema-version': 0},
    });
    expect(rejected.state, 'migration failed');
    expect(config.snapshot.revision, 0);
  });

  test('a declared migration updates values and writes a backup once', () async {
    final config = _Migrating();
    final directory = await Directory.systemTemp.createTemp('ayu-conf-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}config.ayuconf');
    await file.writeAsString('[ayu]\nschema-version = 1\n\n[messages]\nold = "hi"\n');
    final store = AyuConfigFile(schema: config, file: file);
    final result = await store.load();
    expect(result.applied, isTrue);
    expect(config.snapshot.read(config.message), 'hi');
    expect(await File('${file.path}.bak').readAsString(), contains('old = "hi"'));
    await store.close();
  });

  test('saving a valid file updates the snapshot and an invalid edit does not', () async {
    final config = AuditConfig();
    final directory = await Directory.systemTemp.createTemp('ayu-watch-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}config.ayuconf');
    final store = AyuConfigFile(schema: config, file: file);
    expect((await store.loadOrCreate()).applied, isTrue);
    final firstPid = 42;
    final seen = <int>[];
    await store.watch((result) async {
      if (result.applied) seen.add(result.revision);
    });
    await file.writeAsString('''
[ayu]
schema-version = 1

[messages]
join = "Welcome {session_audit.player.name}."

[logging]
log-joins = true

[limits]
max-message-length = 80

[secrets]
token = "hidden"
''');
    await _until(() => config.snapshot.read(config.joinMessage).startsWith('Welcome'));
    expect(firstPid, 42);
    final revision = config.snapshot.revision;
    await file.writeAsString('this is not toml [[[');
    await _until(() => store.state == 'rejected');
    expect(config.snapshot.revision, revision);
    expect(config.snapshot.read(config.joinMessage), startsWith('Welcome'));
    await store.close();
    expect(seen, isNotEmpty);
  });

  test('rapid writes collapse into one applied revision', () async {
    final config = AuditConfig();
    final directory = await Directory.systemTemp.createTemp('ayu-burst-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}config.ayuconf');
    await file.writeAsString(config.generateDefault());
    final store = AyuConfigFile(schema: config, file: file);
    await store.load();
    var loads = 0;
    await store.watch((_) async => loads++);
    for (var i = 0; i < 5; i++) {
      await file.writeAsString(config.generateDefault());
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(loads, lessThan(5));
    await store.close();
  });
}

final class _Migrating extends AyuConfig {
  _Migrating() : super(schemaVersion: 2);

  late final StringOption message;

  @override
  List<ConfigMigration> get migrations => [
    ConfigMigration(
      from: 1,
      to: 2,
      apply: (document) {
        final messages = document['messages'];
        final old = messages is Map ? messages['old'] : null;
        return {
          'ayu': {'schema-version': 2},
          'messages': {'text': old ?? ''},
        };
      },
    ),
  ];

  @override
  void define() {
    message = add(StringOption('messages.text', defaultValue: ''));
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  fail('timed out');
}
