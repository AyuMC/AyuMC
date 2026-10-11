import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_runtime/ayu_runtime.dart';
import 'package:pub_semver/pub_semver.dart';

import 'catalog.dart';
import 'catalog_screen.dart';
import 'console_mode.dart';
import 'keys.dart';
import 'package_desk.dart';
import 'server_control.dart';
import 'view.dart';

/// Homes and clears the current frame. Painting this prefix replaces the screen instead of appending another copy.
const screenFrame = '\x1b[H\x1b[J';

/// Interactive manager. Headless `bin/ayumc.dart` does not use this.
final class ManagerApp {
  ManagerApp({required Directory root, Directory? repository})
    : control = ServerControl(root: root) {
    session = ManagerSession(control: control, repositoryRoot: repository);
    session.desk.onChanged = () => _dirty = true;
  }

  final ServerControl control;
  late final ManagerSession session;
  final KeyDecoder _keys = KeyDecoder();
  StreamSubscription<List<int>>? _keysSubscription;
  StreamSubscription<PluginHostEvent>? _hostEvents;
  Timer? _paintTimer;
  Timer? _clockTimer;
  bool _dirty = true;

  Future<int> run() async {
    LogHub.listeners.add(_onLog);
    final interactive = stdin.hasTerminal && stdout.hasTerminal;
    LogHub.echo = !interactive;
    unawaited(session.desk.refresh());
    if (!interactive) return _lineMode();
    return _rawMode();
  }

  Future<int> _rawMode() async {
    final echo = stdin.echoMode;
    final line = stdin.lineMode;
    stdin.echoMode = false;
    stdin.lineMode = false;
    if (!enableTerminalFeatures()) {
      stdin.echoMode = echo;
      stdin.lineMode = line;
      LogHub.echo = true;
      return _lineMode();
    }
    stdout.write('\x1b[?1049h\x1b[?25l');
    _keysSubscription = stdin.listen(
      (bytes) {
        enableTerminalFeatures();
        try {
          for (final event in _keys.add(bytes)) {
            _onKey(event);
          }
        } catch (error) {
          session.notice('$error');
        }
        _dirty = true;
      },
      cancelOnError: false,
    );
    _paintTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_dirty || session.desk.activity != null) _paint();
    });
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (control.state == ServerRunState.running ||
          control.state == ServerRunState.starting ||
          control.state == ServerRunState.stopping) {
        _dirty = true;
      }
    });
    _paint();
    await _closed.future;
    _paintTimer?.cancel();
    _clockTimer?.cancel();
    await _keysSubscription?.cancel();
    await _hostEvents?.cancel();
    stdout.write('\x1b[?25h\x1b[?1049l');
    stdin.echoMode = echo;
    stdin.lineMode = line;
    LogHub.echo = true;
    LogHub.listeners.remove(_onLog);
    return 0;
  }

  void _onLog(LogRecord record) {
    session.logs.add(record);
    _dirty = true;
  }

  final Completer<void> _closed = Completer<void>();

  void _onKey(KeyEvent event) {
    final screen = session.catalogScreen;
    final text = event.text?.toLowerCase();
    if (event.key == ManagerKey.quit) {
      session.confirmQuit = !session.confirmQuit;
      return;
    }
    if (screen != null && screen.confirming) {
      _dispatch(session.apply(event));
      return;
    }
    if (text == 'y' && session.confirmQuit) {
      unawaited(_quit());
      return;
    }
    if (text == 'q' && session.section != ManagerSection.console) {
      if (screen != null && screen.filtering) {
        _dispatch(session.apply(event));
        return;
      }
      session.confirmQuit = !session.confirmQuit;
      return;
    }
    if (text == 'p' && session.section == ManagerSection.logs) {
      session.toggleLogFollow();
      return;
    }
    if (event.key == ManagerKey.backspace && screen == null) {
      session.backspace();
      return;
    }
    if (event.key == ManagerKey.enter && screen == null) {
      unawaited(_submit(session.takeCommand()));
      return;
    }
    _dispatch(session.apply(event));
  }

  void _dispatch(CatalogCommand? command) {
    if (command == null) return;
    unawaited(_execute(command));
  }

  Future<void> _execute(CatalogCommand command) async {
    if (command.message != null) {
      session.notice(command.message!);
      _dirty = true;
      return;
    }
    final action = command.action;
    if (action == null || action == CatalogAction.home) return;
    try {
      final result = switch (action) {
        CatalogAction.refresh => await session.desk.refresh(),
        CatalogAction.install => await _install(command),
        CatalogAction.enable => await session.desk.enable(command.packageId!),
        CatalogAction.disable => await session.desk.disable(
          command.packageId!,
          cascade: command.cascade,
        ),
        CatalogAction.update => await _update(command),
        CatalogAction.uninstall => await session.desk.uninstall(
          command.packageId!,
          cascade: command.cascade,
        ),
        CatalogAction.home => const DeskResult(true, ''),
      };
      session.notice(result.message);
    } catch (error) {
      session.notice(explainFailure(error));
    }
    _dirty = true;
  }

  Future<DeskResult> _install(CatalogCommand command) async {
    final package = _library(command.archivePath);
    if (package == null)
      return const DeskResult(
        false,
        'That package is no longer in the library. Press R.',
      );
    return session.desk.install(package, enable: command.enable);
  }

  Future<DeskResult> _update(CatalogCommand command) async {
    final package = _library(command.archivePath);
    if (package == null)
      return const DeskResult(
        false,
        'That package is no longer in the library. Press R.',
      );
    return session.desk.update(package);
  }

  LibraryPackage? _library(String? path) {
    if (path == null) return null;
    for (final package in session.desk.inventory.library) {
      if (package.file.path == path) return package;
    }
    return null;
  }

  Future<void> _quit() async {
    if (control.state == ServerRunState.running ||
        control.state == ServerRunState.starting) {
      session.notice(await _control('stop'));
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  Future<void> _submit(String line) async {
    if (line.isEmpty) return;
    final lower = line.toLowerCase();
    if (lower == 'start' || lower == 'stop' || lower == 'restart') {
      session.notice(await _control(lower));
      return;
    }
    if (lower == 'refresh') {
      session.notice((await session.desk.refresh()).message);
      return;
    }
    if (_isPackageCommand(lower)) {
      session.notice(await _packageCommand(line));
      return;
    }
    if (control.state != ServerRunState.running || control.server == null) {
      session.notice('Start the server before sending console commands.');
      return;
    }
    await control.server!.commands.execute(line);
    session.notice('sent: $line');
  }

  bool _isPackageCommand(String lower) {
    final action = lower.split(RegExp(r'\s+')).first;
    return const {
      'install',
      'enable',
      'disable',
      'uninstall',
      'update',
    }.contains(action);
  }

  Future<String> _control(String line) async {
    final result = await session.desk.runLocked(
      () => switch (line) {
        'start' => control.start(),
        'stop' => control.stop(),
        'restart' => control.restart(),
        _ => Future.value('use start, stop, or restart'),
      },
    );
    await _watchHost();
    if (line == 'start' || line == 'restart') await session.desk.refresh();
    return result;
  }

  Future<void> _watchHost() async {
    await _hostEvents?.cancel();
    _hostEvents = null;
    final host = session.desk.host;
    if (host == null) return;
    _hostEvents = host.events.listen((event) {
      if (event is! PluginStateChanged) return;
      session.notice(
        '${event.pluginId}: ${event.from.name} -> ${event.to.name}',
      );
      unawaited(session.desk.reload());
    });
  }

  Future<String> _packageCommand(String line) async {
    final parts = line.split(RegExp(r'\s+'));
    final action = parts.first.toLowerCase();
    final rest = parts.skip(1).toList();
    final cascade = rest.contains('--cascade');
    final disabled = rest.contains('--disabled');
    final arg = rest.where((part) => !part.startsWith('--')).firstOrNull;
    try {
      switch (action) {
        case 'install':
          if (arg == null) return 'install <file.ayu>';
          final opened = await _openCommandPackage(arg);
          if (opened is String) return opened;
          return (await session.desk.install(
            opened as LibraryPackage,
            enable: !disabled,
          )).message;
        case 'update':
          if (arg == null) return 'update <file.ayu>';
          final opened = await _openCommandPackage(arg);
          if (opened is String) return opened;
          return (await session.desk.update(opened as LibraryPackage)).message;
        case 'enable':
          if (arg == null) return 'enable <id>';
          return (await session.desk.enable(arg)).message;
        case 'disable':
          if (arg == null) return 'disable <id>';
          return (await session.desk.disable(arg, cascade: cascade)).message;
        case 'uninstall':
          if (arg == null) return 'uninstall <id>';
          return (await session.desk.uninstall(arg, cascade: cascade)).message;
        default:
          return 'install, enable, disable, update, uninstall, refresh';
      }
    } catch (error) {
      return explainFailure(error);
    }
  }

  Future<Object> _openCommandPackage(String path) async {
    final file = File(path);
    try {
      final opened = await AyuPackage.open(file);
      try {
        await opened.verifyArtifacts();
        final profile = session.desk.inventory.profileId.isEmpty
            ? 'AyuMC-1.8.9-release'
            : session.desk.inventory.profileId;
        final context = ScanContext(
          profileId: profile,
          apiVersion: Version.parse(IpcProtocol.apiVersion),
          target: RuntimeTarget.current(),
          runtimeSdk: session.desk.host?.runtime?.version,
        );
        return LibraryPackage(
          file: file,
          manifest: opened.manifest,
          blockers: compatibilityBlockers(opened.manifest, context),
          warnings: compatibilityWarnings(opened.manifest, context),
        );
      } finally {
        await opened.close();
      }
    } on PackageException catch (error) {
      return explainFailure(error);
    }
  }

  void _paint() {
    _dirty = false;
    final width = stdout.hasTerminal ? stdout.terminalColumns : 80;
    stdout.write('$screenFrame${session.render(width: width)}');
  }

  Future<int> _lineMode() async {
    stdout.writeln(
      'AyuMC manager, line mode. This terminal has no raw keyboard.',
    );
    stdout.writeln(
      'Commands: start, stop, restart, refresh, plugins, events, install <file.ayu>, quit',
    );
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final text = line.trim();
      if (text == 'quit') {
        if (control.state == ServerRunState.running) await _control('stop');
        break;
      }
      if (text == 'logs' || text == 'home') {
        session.section = text == 'logs'
            ? ManagerSection.logs
            : ManagerSection.dashboard;
        stdout.writeln(session.render(color: false));
        continue;
      }
      if (text == 'plugins' || text == 'events') {
        await session.desk.refresh();
        session.section = text == 'plugins'
            ? ManagerSection.plugins
            : ManagerSection.events;
        stdout.writeln(session.render(color: false));
        continue;
      }
      if (text.startsWith('console ')) {
        session.section = ManagerSection.console;
        await _submit(text.substring('console '.length));
        stdout.writeln(session.notices.isEmpty ? '' : session.notices.last);
        continue;
      }
      if (text == 'start' || text == 'stop' || text == 'restart')
        session.section = ManagerSection.controls;
      await _submit(text);
      stdout.writeln(session.notices.isEmpty ? '' : session.notices.last);
    }
    LogHub.listeners.remove(_onLog);
    LogHub.echo = true;
    return 0;
  }
}
