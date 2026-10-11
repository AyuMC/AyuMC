import 'dart:io';

import 'package:ayu_plugin_api/ayu_plugin_api.dart';

import 'config/audit_config.dart';
import 'listeners/connection_listener.dart';

final class SessionAudit extends AyuPlugin {
  SessionAudit(this.context) : config = AuditConfig() {
    _connections = ConnectionListener(context: context, config: config);
  }

  @override
  final PluginContext context;
  final AuditConfig config;
  late final ConnectionListener _connections;
  AyuConfigFile? _file;

  @override
  List<Listener> get listeners => [_connections];

  @override
  Future<void> onEnable() async {
    final file = File(
      '${context.dataDirectory}${Platform.pathSeparator}config.ayuconf',
    );
    _file = AyuConfigFile(schema: config, file: file);
    await _report(await _file!.loadOrCreate());
    await _file!.watch(_report);
  }

  Future<void> _report(ConfigLoadResult result) async {
    if (result.applied) {
      context.log.info('[SessionAudit] config ${result.summary}');
    } else {
      context.log.error('[SessionAudit] config rejected: ${result.summary}');
    }
    context.reportConfigStatus(
      state: result.state,
      revision: result.revision,
      schemaVersion: config.schemaVersion,
      error: result.applied ? null : result.summary,
    );
  }

  @override
  Future<void> onDisable() async {
    await _file?.close();
  }
}
