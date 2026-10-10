import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayu_runtime/ayu_runtime.dart';

/// `plugin <list|info|install|enable|disable|update|uninstall> ...` on the
/// server console. Every operation is a live operation on the host.
final class PluginConsoleCommand {
  PluginConsoleCommand(this._plugins, this._log);

  final PluginHost _plugins;
  final Logger _log;

  static const usage =
      'plugin list | plugin info <id> | plugin install <file.ayu> [--disabled] | plugin enable <id> | '
      'plugin disable <id> | plugin update <file.ayu> | plugin uninstall <id>';

  Command get command => Command(name: 'plugin', description: 'Manage plugins. $usage', execute: execute);

  Future<void> execute(List<String> args) async {
    if (args.isEmpty) {
      _log.info(usage);
      return;
    }
    final action = args.first;
    final rest = args.skip(1).toList();
    try {
      switch (action) {
        case 'list':
          _list();
        case 'info':
          _info(_requireArg(rest, 'id'));
        case 'install':
          final snapshot = await _plugins.install(File(_requireArg(rest, 'file')), enable: !rest.contains('--disabled'));
          _log.info('installed $snapshot');
        case 'enable':
          _log.info('enabled ${await _plugins.enable(_requireArg(rest, 'id'))}');
        case 'disable':
          _log.info('disabled ${await _plugins.disable(_requireArg(rest, 'id'))}');
        case 'update':
          _log.info('updated ${await _plugins.update(File(_requireArg(rest, 'file')))}');
        case 'uninstall':
          final id = _requireArg(rest, 'id');
          await _plugins.uninstall(id);
          _log.info('uninstalled $id');
        default:
          _log.warn('unknown plugin action "$action". $usage');
      }
    } on PluginHostException catch (e) {
      _log.error(e.toString());
    } on PackageException catch (e) {
      _log.error(e.toString());
    } on ArgumentError catch (e) {
      _log.warn('${e.message}. $usage');
    }
  }

  void _list() {
    final plugins = _plugins.plugins;
    if (plugins.isEmpty) {
      _log.info('no plugins installed (${_plugins.layout.root.path})');
      return;
    }
    for (final plugin in plugins) {
      _log.info('$plugin${plugin.pid == null ? '' : ' pid ${plugin.pid}'}');
    }
  }

  void _info(String id) {
    final plugin = _plugins.plugin(id);
    if (plugin == null) {
      _log.warn('plugin "$id" is not installed');
      return;
    }
    _log.info('${plugin.name} ${plugin.version} [${plugin.state.name}] enabled=${plugin.enabled}');
    _log.info('  install: ${plugin.installDirectory}');
    _log.info('  data:    ${plugin.dataDirectory}');
    _log.info('  capabilities: ${plugin.capabilities.join(', ')}');
    if (plugin.dependencies.isNotEmpty) _log.info('  dependencies: ${plugin.dependencies.join('; ')}');
    _log.info('  commands: ${_plugins.registry.commandsOf(id).map((c) => c.spec.name).join(', ')}');
    _log.info('  events:   ${_plugins.registry.subscriptionsOf(id).join(', ')}');
    _log.info('  restarts: ${plugin.restartCount}, dropped events: ${plugin.droppedEvents}');
    if (plugin.lastError != null) _log.warn('  last error: ${plugin.lastError} (exit code ${plugin.lastExitCode})');
    if (plugin.stderrTail.isNotEmpty) _log.warn('  stderr: ${plugin.stderrTail}');
  }

  static String _requireArg(List<String> rest, String what) {
    final value = rest.where((a) => !a.startsWith('--')).firstOrNull;
    if (value == null) throw ArgumentError('missing <$what>');
    return value;
  }
}
