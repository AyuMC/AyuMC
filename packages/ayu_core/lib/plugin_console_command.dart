import 'dart:io';

import 'package:ayu_commands/ayu_commands.dart';
import 'package:ayu_logging/logger.dart';
import 'package:ayu_runtime/ayu_runtime.dart';

/// `plugin ...` or `event ...` on the server console. Both operate on the
/// same host; the package type decides whether files land in `plugins/` or
/// `events/`.
final class PackageConsoleCommand {
  PackageConsoleCommand(this._plugins, this._log, {required this.eventPacks});

  final PluginHost _plugins;
  final Logger _log;
  final bool eventPacks;

  String get _name => eventPacks ? 'event' : 'plugin';

  String get usage =>
      '$_name list | $_name info <id> | $_name install <file.ayu> [--disabled] | $_name enable <id> | '
      '$_name disable <id> [--cascade] | $_name update <file.ayu> | $_name uninstall <id> [--cascade]';

  Command get command => Command(name: _name, description: 'Manage ${eventPacks ? 'event packs' : 'plugins'}. $usage', execute: execute);

  Future<void> execute(List<String> args) async {
    if (args.isEmpty) {
      _log.info(usage);
      return;
    }
    final action = args.first;
    final rest = args.skip(1).toList();
    final cascade = rest.contains('--cascade');
    try {
      switch (action) {
        case 'list':
          _list();
        case 'info':
          _info(_requireArg(rest, 'id'));
        case 'install':
          await _install(rest);
        case 'enable':
          _log.info('enabled ${await _plugins.enable(_requireArg(rest, 'id'))}');
        case 'disable':
          _log.info('disabled ${await _plugins.disable(_requireArg(rest, 'id'), cascade: cascade)}');
        case 'update':
          _log.info('updated ${await _plugins.update(File(_requireArg(rest, 'file')))}');
        case 'uninstall':
          final id = _requireArg(rest, 'id');
          await _plugins.uninstall(id, cascade: cascade);
          _log.info('uninstalled $id');
        default:
          _log.warn('unknown $_name action "$action". $usage');
      }
    } on PluginHostException catch (e) {
      _log.error(e.toString());
    } on PackageException catch (e) {
      _log.error(e.toString());
    } on ArgumentError catch (e) {
      _log.warn('${e.message}. $usage');
    }
  }

  Future<void> _install(List<String> rest) async {
    final file = File(_requireArg(rest, 'file'));
    final package = await AyuPackage.open(file);
    try {
      if (package.manifest.isEventPack != eventPacks) {
        throw ArgumentError(
            '${file.path} is a ${package.manifest.packageType.wireName}; use the ${package.manifest.isEventPack ? 'event' : 'plugin'} command');
      }
    } finally {
      await package.close();
    }
    final snapshot = await _plugins.install(file, enable: !rest.contains('--disabled'));
    _log.info('installed $snapshot');
  }

  void _list() {
    final packages = eventPacks ? _plugins.eventPacks : _plugins.regularPlugins;
    if (packages.isEmpty) {
      _log.info('no ${eventPacks ? 'event packs' : 'plugins'} installed');
      return;
    }
    for (final package in packages) {
      _log.info('$package${package.pid == null ? '' : ' pid ${package.pid}'}');
    }
  }

  void _info(String id) {
    final package = _plugins.plugin(id);
    if (package == null || package.isEventPack != eventPacks) {
      _log.warn('$_name "$id" is not installed');
      return;
    }
    _log.info('${package.name} ${package.version} [${package.state.name}] enabled=${package.enabled}');
    _log.info('  install: ${package.installDirectory}');
    _log.info('  data:    ${package.dataDirectory}');
    if (package.provides.isNotEmpty) _log.info('  provides: ${package.provides.join('; ')}');
    if (package.requiredContracts.isNotEmpty) _log.info('  requires: ${package.requiredContracts.join('; ')}');
    if (package.optionalContracts.isNotEmpty) _log.info('  optional: ${package.optionalContracts.join('; ')}');
    _log.info('  commands: ${_plugins.registry.commandsOf(id).map((c) => c.spec.name).join(', ')}');
    _log.info('  subscribed: ${_plugins.contracts.subscriptionsOf(id).join(', ')}');
    if (package.lastError != null) _log.warn('  last error: ${package.lastError} (exit code ${package.lastExitCode})');
  }

  static String _requireArg(List<String> rest, String what) {
    final value = rest.where((a) => !a.startsWith('--')).firstOrNull;
    if (value == null) throw ArgumentError('missing <$what>');
    return value;
  }
}
