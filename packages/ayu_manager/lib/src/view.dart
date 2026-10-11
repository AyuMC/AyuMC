import 'dart:io';

import 'package:ayu_logging/ayu_logging.dart';

import 'catalog_screen.dart';
import 'keys.dart';
import 'log_buffer.dart';
import 'package_desk.dart';
import 'server_control.dart';

enum ManagerSection { logs, plugins, events, console, dashboard, controls }

/// UI state that does not touch the terminal. Tests drive it with [apply].
final class ManagerSession {
  ManagerSession({
    required this.control,
    PackageDesk? desk,
    LogBuffer? logs,
    Directory? repositoryRoot,
  }) : logs = logs ?? LogBuffer(),
       desk =
           desk ??
           PackageDesk(control: control, repositoryRoot: repositoryRoot) {
    pluginScreen = CatalogScreen(events: false, desk: this.desk);
    eventScreen = CatalogScreen(events: true, desk: this.desk);
  }

  final ServerControl control;
  final PackageDesk desk;
  final LogBuffer logs;
  late final CatalogScreen pluginScreen;
  late final CatalogScreen eventScreen;

  ManagerSection section = ManagerSection.dashboard;
  bool followTail = true;

  /// When log following is paused, the view stays on this many lines.
  int? logPin;
  bool confirmQuit = false;
  final StringBuffer command = StringBuffer();
  final List<String> notices = [];
  String lastKey = '';

  CatalogScreen? get catalogScreen => switch (section) {
    ManagerSection.plugins => pluginScreen,
    ManagerSection.events => eventScreen,
    _ => null,
  };

  CatalogCommand? apply(KeyEvent event) {
    if (event.key != null) lastKey = event.key!.name;
    if (event.text != null) lastKey = event.text!;
    if (event.key == ManagerKey.quit) {
      confirmQuit = !confirmQuit;
      return null;
    }
    final screen = catalogScreen;
    if (screen != null && !screen.filtering) {
      final destination = _destination(event);
      if (destination != null && command.isEmpty && !screen.confirming) {
        screen.detail = false;
        screen.confirming = false;
        section = destination;
        return null;
      }
    }
    if (screen != null) {
      final commandResult = screen.handle(event);
      if (commandResult?.action == CatalogAction.home) {
        section = ManagerSection.dashboard;
        return null;
      }
      return commandResult;
    }
    final destination = _destination(event);
    if (destination != null && command.isEmpty) {
      section = destination;
      return null;
    }
    if (event.key == ManagerKey.pause) toggleLogFollow();
    if (event.key == ManagerKey.backspace) backspace();
    if (event.key == ManagerKey.escape) section = ManagerSection.dashboard;
    if (event.text != null &&
        (section == ManagerSection.console ||
            section == ManagerSection.controls)) {
      command.write(event.text);
    }
    return null;
  }

  ManagerSection? _destination(KeyEvent event) {
    final key = event.key;
    if (key != null) {
      return switch (key) {
        ManagerKey.f1 => ManagerSection.logs,
        ManagerKey.f2 => ManagerSection.plugins,
        ManagerKey.f3 => ManagerSection.events,
        ManagerKey.f4 => ManagerSection.console,
        ManagerKey.f5 => ManagerSection.dashboard,
        ManagerKey.f6 => ManagerSection.controls,
        _ => null,
      };
    }
    if (command.isNotEmpty) return null;
    return switch (event.text) {
      '1' => ManagerSection.logs,
      '2' => ManagerSection.plugins,
      '3' => ManagerSection.events,
      '4' => ManagerSection.console,
      '5' => ManagerSection.dashboard,
      '6' => ManagerSection.controls,
      _ => null,
    };
  }

  void toggleLogFollow() {
    followTail = !followTail;
    logPin = followTail ? null : logs.lines.length;
  }

  void backspace() {
    final value = command.toString();
    command
      ..clear()
      ..write(value.isEmpty ? '' : value.substring(0, value.length - 1));
  }

  String takeCommand() {
    final value = command.toString().trim();
    command.clear();
    return value;
  }

  void notice(String message) {
    if (message.trim().isEmpty) return;
    notices.add(message);
    if (notices.length > 6) notices.removeAt(0);
  }

  String render({bool color = true, int width = 80}) {
    String paint(String text, String code) =>
        color ? '\x1b[${code}m$text\x1b[0m' : text;
    final stateColor = switch (control.state) {
      ServerRunState.running => '32',
      ServerRunState.failed => '31',
      ServerRunState.starting || ServerRunState.stopping => '33',
      ServerRunState.stopped => '90',
    };
    final tabs = [
      (ManagerSection.logs, '1  Logs'),
      (ManagerSection.plugins, '2  Plugins'),
      (ManagerSection.events, '3  Events'),
      (ManagerSection.console, '4  Console'),
      (ManagerSection.dashboard, '5  Home'),
      (ManagerSection.controls, '6  Power'),
    ];
    final tabBar = tabs
        .map((tab) {
          final label = ' ${tab.$2} ';
          return tab.$1 == section ? paint(label, '30;46') : paint(label, '2');
        })
        .join(' ');
    final rule = '─' * (width.clamp(48, 100) - 4);

    final buffer = StringBuffer()
      ..writeln(paint('  AYUMC', '1;36'))
      ..writeln(paint('  Minecraft Java 1.8.9   ·   protocol 47', '2'))
      ..writeln()
      ..writeln(
        '  ${paint(control.state.name.toUpperCase(), '1;$stateColor')}'
        '    ${paint('port ${control.listeningPort ?? _configuredPort()}', '2')}'
        '${control.startedAt == null ? '' : '    ${paint('up ${_uptime()}', '2')}'}',
      )
      ..writeln()
      ..writeln('  $tabBar')
      ..writeln(paint('  $rule', '2'))
      ..writeln();

    switch (section) {
      case ManagerSection.logs:
        buffer.writeln(
          '  ${paint('Newest server lines. P pauses this view. ${logs.capacity} lines are kept here.', '2')}',
        );
        if (logs.dropped > 0)
          buffer.writeln(
            '  ${paint('${logs.dropped} older lines left this view.', '33')}',
          );
        buffer.writeln();
        final end = !followTail && logPin != null
            ? logPin!.clamp(0, logs.lines.length)
            : logs.lines.length;
        final start = end > 16 ? end - 16 : 0;
        final visible = logs.lines.skip(start).take(end - start);
        if (visible.isEmpty)
          buffer.writeln(
            '  ${paint('No log lines yet. Start the server from 6 Power.', '2')}',
          );
        for (final line in visible) {
          final clock =
              '${line.time.hour.toString().padLeft(2, '0')}:${line.time.minute.toString().padLeft(2, '0')}:${line.time.second.toString().padLeft(2, '0')}';
          final levelColor = switch (line.level) {
            LogLevel.error => '31',
            LogLevel.warn => '33',
            LogLevel.info => '32',
          };
          buffer.writeln(
            '  ${paint(clock, '2')}  ${paint(line.level.name.toUpperCase().padRight(5), levelColor)}  ${line.loggerName}  ${line.message}',
          );
        }
      case ManagerSection.plugins:
        pluginScreen.render(buffer, paint, width);
      case ManagerSection.events:
        eventScreen.render(buffer, paint, width);
      case ManagerSection.console:
        buffer
          ..writeln(
            '  ${paint('Server console. This is not Minecraft chat.', '2')}',
          )
          ..writeln()
          ..writeln(
            '  ${paint('>', '36')} ${command.toString()}${paint('▏', '36')}',
          );
      case ManagerSection.dashboard:
        buffer
          ..writeln('  ${paint('Home', '1')}')
          ..writeln()
          ..writeln(
            '  Press ${paint('6', '1;36')} and type ${paint('start', '1')}, then Enter.',
          )
          ..writeln(
            '  Press ${paint('1', '1;36')} to ${paint('6', '1;36')} to move. The same keys work as F1 to F6.',
          )
          ..writeln(
            '  ${paint('2', '1;36')} and ${paint('3', '1;36')} list packages that are available and packages that are installed.',
          )
          ..writeln(
            '  ${paint('Player counts are not shown until a session source reports them.', '2')}',
          );
      case ManagerSection.controls:
        buffer
          ..writeln('  ${paint('Power', '1')}')
          ..writeln()
          ..writeln('  ${paint('start', '32')}      bring the server up')
          ..writeln('  ${paint('stop', '31')}       shut it down')
          ..writeln('  ${paint('restart', '33')}    stop, then start')
          ..writeln()
          ..writeln(
            '  ${paint('>', '36')} ${command.toString()}${paint('▏', '36')}',
          )
          ..writeln()
          ..writeln(
            control.lastError == null
                ? '  ${paint('No failure recorded.', '2')}'
                : '  ${paint(control.lastError!, '31')}',
          );
    }
    buffer
      ..writeln()
      ..writeln(paint('  $rule', '2'));
    if (confirmQuit) {
      buffer.writeln(
        '  ${paint('Stop the server and quit?  Y confirm    Q cancel', '1;33')}',
      );
    } else {
      buffer.writeln(
        '  ${paint(_hints(), '2')}${lastKey.isEmpty ? '' : '    ${paint(lastKey, '36')}'}',
      );
    }
    for (final item in notices) {
      buffer.writeln('  ${paint(item, '36')}');
    }
    return buffer.toString();
  }

  String _hints() {
    final screen = catalogScreen;
    if (screen == null)
      return '1-6 move    Enter run    P pause logs    Q quit';
    if (screen.confirming) return 'Y confirm    N cancel';
    if (screen.filtering) return 'Type to filter    Enter done    Esc clear';
    if (screen.detail)
      return 'A install+enable    N install    E D U X    Esc back';
    return 'Up Down select    Enter inspect    / filter    R refresh    Q quit';
  }

  int _configuredPort() {
    final port = control.listeningPort;
    return port ?? 25565;
  }

  String _uptime() {
    final start = control.startedAt;
    if (start == null) return '';
    final elapsed = DateTime.now().difference(start);
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${elapsed.inHours}:$minutes:$seconds';
  }
}
