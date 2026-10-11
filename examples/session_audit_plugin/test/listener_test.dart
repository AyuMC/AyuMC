import 'package:ayu_plugin_api/ayu_plugin_api.dart';
import 'package:session_audit_plugin/config/audit_config.dart';
import 'package:session_audit_plugin/listeners/connection_listener.dart';
import 'package:test/test.dart';

void main() {
  test('one snapshot supplies both the switch and the message', () {
    final config = AuditConfig();
    config.applyDocument({
      'messages': {'join': 'Hello {session_audit.player.name}'},
      'logging': {'log-joins': true},
    });
    final first = config.snapshot;
    config.applyDocument({
      'messages': {'join': 'Bye {session_audit.player.name}'},
      'logging': {'log-joins': false},
    });

    expect(
      formatAuditLine(
        snapshot: first,
        enabled: config.logJoins,
        message: config.joinMessage,
        name: 'Steve',
      ),
      'Hello Steve',
    );
    expect(
      formatAuditLine(
        snapshot: config.snapshot,
        enabled: config.logJoins,
        message: config.joinMessage,
        name: 'Steve',
      ),
      isNull,
    );
  });

  test('the typed join handler logs the default message', () {
    final config = AuditConfig();
    final link = _LogLink();
    final listener = ConnectionListener(
      context: PluginContext(
        plugin: const PluginDescriptor(
          id: 'session_audit',
          name: 'Session Audit',
          version: '1.0.0',
        ),
        installDirectory: '/install',
        dataDirectory: '/data',
        capabilities: const {'events', 'config'},
        config: const {},
        link: link,
      ),
      config: config,
    );
    listener.handlers.first.dispatch({
      'name': 'Steve',
      'uuid': 'u',
      'entityId': 1,
    });
    expect(link.messages.single, '[SessionAudit] PLAYER_JOINED username=Steve');
  });
}

final class _LogLink implements HostLink {
  final messages = <String>[];

  @override
  bool get isConnected => true;

  @override
  bool notify(String method, [Object? params]) {
    if (params is Map && params['message'] is String) {
      messages.add(params['message'] as String);
    }
    return true;
  }

  @override
  Future<Object?> request(
    String method, [
    Object? params,
    Duration? timeout,
  ]) async => const {};
}
