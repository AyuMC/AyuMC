import 'package:ayu_runtime/ayu_runtime.dart';

import 'catalog.dart';
import 'keys.dart';
import 'package_desk.dart';

enum CatalogAction {
  refresh,
  install,
  enable,
  disable,
  update,
  uninstall,
  home,
}

/// A key the package screen wants the app to perform. Confirmation happens before this is returned.
final class CatalogCommand {
  const CatalogCommand.message(this.message)
    : action = null,
      archivePath = null,
      packageId = null,
      enable = false,
      cascade = false;

  const CatalogCommand.action(
    this.action, {
    this.archivePath,
    this.packageId,
    this.enable = false,
    this.cascade = false,
  }) : message = null;

  final String? message;
  final CatalogAction? action;
  final String? archivePath;
  final String? packageId;
  final bool enable;
  final bool cascade;
}

/// Keyboard state for the plugin screen or the event-pack screen.
final class CatalogScreen {
  CatalogScreen({required this.events, required this.desk});

  final bool events;
  final PackageDesk desk;

  String filter = '';
  bool filtering = false;
  bool detail = false;
  bool confirming = false;
  int detailOffset = 0;
  String? selectedIdentity;
  String confirmText = '';
  CatalogCommand? _pending;

  bool get busy => desk.busy;

  List<CatalogRow> get rows => buildCatalogRows(
    events: events,
    inventory: desk.inventory,
    filter: filter,
  );

  CatalogCommand? handle(KeyEvent event) {
    if (confirming) return _confirm(event);
    if (filtering) return _filter(event);
    if (event.key == ManagerKey.escape) {
      if (detail) {
        detail = false;
        return null;
      }
      if (filter.isNotEmpty) {
        filter = '';
        return null;
      }
      return const CatalogCommand.action(CatalogAction.home);
    }
    if (!detail && event.key == ManagerKey.up) {
      _move(-1);
      return null;
    }
    if (!detail && event.key == ManagerKey.down) {
      _move(1);
      return null;
    }
    if (detail && event.key == ManagerKey.up) {
      if (detailOffset > 0) detailOffset--;
      return null;
    }
    if (detail && event.key == ManagerKey.down) {
      detailOffset++;
      return null;
    }
    if (event.key == ManagerKey.enter && !detail) {
      if (_selected() == null)
        return const CatalogCommand.message('Nothing to inspect.');
      detail = true;
      detailOffset = 0;
      return null;
    }
    switch (event.text?.toLowerCase()) {
      case '/':
        filtering = true;
        return null;
      case 'r':
        return const CatalogCommand.action(CatalogAction.refresh);
      case 'i':
        if (_selected() == null)
          return const CatalogCommand.message('Nothing to inspect.');
        detail = true;
        detailOffset = 0;
        return null;
      case 'a':
        return _askInstall(enable: true);
      case 'n':
        return _askInstall(enable: false);
      case 'e':
        return _askEnable();
      case 'd':
        return _askDisable();
      case 'u':
        return _askUpdate();
      case 'x':
        return _askUninstall();
      default:
        return null;
    }
  }

  CatalogCommand? _confirm(KeyEvent event) {
    final text = event.text?.toLowerCase();
    if (text == 'y') {
      final command = _pending;
      confirming = false;
      _pending = null;
      return command;
    }
    if (text == 'n' || event.key == ManagerKey.escape) {
      confirming = false;
      _pending = null;
      return const CatalogCommand.message('Cancelled.');
    }
    return null;
  }

  CatalogCommand? _filter(KeyEvent event) {
    if (event.key == ManagerKey.escape) {
      filtering = false;
      filter = '';
      return null;
    }
    if (event.key == ManagerKey.enter) {
      filtering = false;
      return null;
    }
    if (event.key == ManagerKey.backspace) {
      if (filter.isNotEmpty) filter = filter.substring(0, filter.length - 1);
      return null;
    }
    final text = event.text;
    if (text != null && text != '\n' && text != '\r') filter += text;
    return null;
  }

  CatalogCommand? _askInstall({required bool enable}) {
    final row = _selected();
    final library = row?.library;
    if (row?.failure != null)
      return const CatalogCommand.message(
        'This file could not be read. Open it with Enter for the error.',
      );
    if (library == null)
      return const CatalogCommand.message('Select an available package first.');
    if (!library.compatible)
      return CatalogCommand.message(library.blockers.join(' '));
    final installed = desk.inventory.installedById(library.manifest.id);
    if (installed != null &&
        installed.manifest.version == library.manifest.version) {
      return CatalogCommand.message(
        '${library.manifest.id} ${library.manifest.version} is already installed.',
      );
    }
    if (installed != null)
      return const CatalogCommand.message(
        'That version is already installed. Press U to replace it.',
      );
    _arm(
      enable
          ? 'Install ${library.manifest.id} ${library.manifest.version} and enable it?\n${_preview(library)}'
          : 'Install ${library.manifest.id} ${library.manifest.version} and leave it disabled?\n${_preview(library)}',
      CatalogCommand.action(
        CatalogAction.install,
        archivePath: library.file.path,
        enable: enable,
      ),
    );
    return null;
  }

  CatalogRow? _installedSelection() {
    final row = _selected();
    final installed = row?.installed;
    final library = row?.library;
    if (installed == null) return null;
    if (library != null &&
        library.manifest.version != installed.manifest.version)
      return null;
    return row;
  }

  CatalogCommand? _askEnable() {
    final installed = _installedSelection()?.installed;
    if (installed == null)
      return const CatalogCommand.message(
        'Select an installed package to enable.',
      );
    if (desk.serverRunning && installed.state == PluginState.active) {
      return CatalogCommand.message(
        '${installed.manifest.id} is already active.',
      );
    }
    _arm(
      'Enable ${installed.manifest.id} ${installed.manifest.version}?\n${desk.serverRunning ? 'The worker starts now, without restarting the server.' : 'The server is stopped. This only marks it to start on the next launch.'}',
      CatalogCommand.action(
        CatalogAction.enable,
        packageId: installed.manifest.id,
      ),
    );
    return null;
  }

  CatalogCommand? _askDisable() {
    final installed = _installedSelection()?.installed;
    if (installed == null)
      return const CatalogCommand.message(
        'Select an installed package to disable.',
      );
    final dependents = packageDependents(desk.inventory, installed.manifest.id);
    final blocking = dependents
        .where(
          (package) => desk.serverRunning
              ? package.state == PluginState.active
              : package.enabled,
        )
        .toList();
    if (blocking.isNotEmpty) {
      return CatalogCommand.message(
        'Cannot disable ${installed.manifest.id}. Required by ${blocking.map((package) => package.manifest.id).join(', ')}.',
      );
    }
    final consumers = contractConsumers(desk.inventory, installed.manifest)
        .where(
          (package) => desk.serverRunning
              ? package.state == PluginState.active
              : package.enabled,
        )
        .toList();
    if (consumers.isNotEmpty) {
      final names = consumers.map((package) => package.manifest.id).join(', ');
      _arm(
        'Disable ${installed.manifest.id}? $names require its contracts and will be suspended.\nY suspends them. N cancels.',
        CatalogCommand.action(
          CatalogAction.disable,
          packageId: installed.manifest.id,
          cascade: true,
        ),
      );
      return null;
    }
    _arm(
      'Disable ${installed.manifest.id}?',
      CatalogCommand.action(
        CatalogAction.disable,
        packageId: installed.manifest.id,
      ),
    );
    return null;
  }

  CatalogCommand? _askUpdate() {
    final row = _selected();
    final library = row?.library;
    final installed =
        row?.installed ??
        (row == null
            ? null
            : desk.inventory.installedById(row.library?.manifest.id ?? ''));
    LibraryPackage? candidate = library;
    final selectedInstalled = row?.installed;
    if (candidate == null && selectedInstalled != null) {
      final others = desk.inventory.library
          .where(
            (package) =>
                package.manifest.id == selectedInstalled.manifest.id &&
                package.manifest.version !=
                    selectedInstalled.manifest.version &&
                package.compatible,
          )
          .toList();
      if (others.isEmpty)
        return const CatalogCommand.message(
          'No other version is in the library.',
        );
      if (others.length > 1)
        return const CatalogCommand.message(
          'Select the version under Other versions.',
        );
      candidate = others.single;
    }
    if (candidate == null || installed == null)
      return const CatalogCommand.message(
        'Select an installed package or another version.',
      );
    if (!candidate.compatible)
      return CatalogCommand.message(candidate.blockers.join(' '));
    _arm(
      'Replace ${installed.manifest.id} ${installed.manifest.version} with ${candidate.manifest.version}?\n'
      '${desk.serverRunning ? 'The running worker is stopped and the new version is started. If startup fails, the previous version is restored.' : 'The server is stopped, so the files change now and the new version starts on the next launch.'}',
      CatalogCommand.action(
        CatalogAction.update,
        archivePath: candidate.file.path,
      ),
    );
    return null;
  }

  CatalogCommand? _askUninstall() {
    final installed = _installedSelection()?.installed;
    if (installed == null)
      return const CatalogCommand.message(
        'Select an installed package to uninstall.',
      );
    final dependents = packageDependents(desk.inventory, installed.manifest.id);
    if (dependents.isNotEmpty) {
      return CatalogCommand.message(
        'Cannot uninstall ${installed.manifest.id}. Required by ${dependents.map((package) => package.manifest.id).join(', ')}.',
      );
    }
    final consumers = contractConsumers(desk.inventory, installed.manifest)
        .where(
          (package) => desk.serverRunning
              ? package.state == PluginState.active
              : package.enabled,
        )
        .toList();
    if (consumers.isNotEmpty) {
      final names = consumers.map((package) => package.manifest.id).join(', ');
      _arm(
        'Uninstall ${installed.manifest.id}? $names require its contracts.\nThe library file is not deleted. Y continues. N cancels.',
        CatalogCommand.action(
          CatalogAction.uninstall,
          packageId: installed.manifest.id,
          cascade: true,
        ),
      );
      return null;
    }
    _arm(
      'Uninstall ${installed.manifest.id}? The installed copy is removed. The original .ayu file and saved plugin data stay.',
      CatalogCommand.action(
        CatalogAction.uninstall,
        packageId: installed.manifest.id,
      ),
    );
    return null;
  }

  void _arm(String text, CatalogCommand command) {
    confirmText = text;
    _pending = command;
    confirming = true;
  }

  String _preview(LibraryPackage package) {
    final kind = package.manifest.isEventPack ? 'Event pack' : 'Plugin';
    final provides = package.manifest.provides
        .map((contract) => contract.id)
        .join(', ');
    final requires = package.manifest.requiredEvents
        .map((event) => event.id)
        .join(', ');
    final where = desk.serverRunning
        ? 'The server is running, so a supported change happens without a restart.'
        : 'The server is stopped, so the package is saved but not running.';
    return '$kind. ${provides.isEmpty ? '' : 'Provides $provides. '}${requires.isEmpty ? '' : 'Requires $requires. '}$where';
  }

  void _move(int delta) {
    final selectable = rows.where((row) => row.selectable).toList();
    if (selectable.isEmpty) return;
    final index = selectable.indexWhere(
      (row) => row.identity == selectedIdentity,
    );
    final next = (index < 0 ? 0 : index + delta).clamp(
      0,
      selectable.length - 1,
    );
    selectedIdentity = selectable[next].identity;
  }

  CatalogRow? _selected() {
    final selectable = rows.where((row) => row.selectable).toList();
    if (selectable.isEmpty) {
      selectedIdentity = null;
      return null;
    }
    final index = selectable.indexWhere(
      (row) => row.identity == selectedIdentity,
    );
    final row = selectable[index < 0 ? 0 : index];
    selectedIdentity = row.identity;
    return row;
  }

  void render(
    StringBuffer buffer,
    String Function(String text, String code) paint,
    int width,
  ) {
    final kind = events ? 'Event packs' : 'Plugins';
    final list = rows;
    final selected = _selected();
    final inner = width.clamp(48, 100);
    buffer.writeln('  ${paint(kind, '1')}   ${paint(_counts(), '2')}');
    if (desk.inventory.profileWarning != null) {
      buffer.writeln('  ${paint(desk.inventory.profileWarning!, '33')}');
    }
    if (filtering) {
      buffer.writeln('  ${paint('Filter', '36')}  $filter${paint('▏', '36')}');
    } else if (filter.isNotEmpty) {
      buffer.writeln('  ${paint('Filter "$filter"   Esc clears', '2')}');
    }
    buffer.writeln();
    if (detail && selected != null) {
      _renderDetail(buffer, paint, selected, inner);
    } else if (list.isEmpty) {
      _renderEmpty(buffer, paint);
    } else {
      _renderList(buffer, paint, list, selected, inner);
    }
    if (confirming) {
      buffer.writeln();
      for (final line in confirmText.split('\n')) {
        buffer.writeln('  ${paint(line, '1;33')}');
      }
    }
    if (desk.activity != null) {
      buffer.writeln();
      buffer.writeln('  ${paint(desk.activity!, '36')}');
    }
  }

  String _counts() {
    final installed = desk.inventory.installed
        .where((package) => package.manifest.isEventPack == events)
        .length;
    final available = rows
        .where(
          (row) =>
              row.selectable &&
              row.library != null &&
              row.installed == null &&
              row.failure == null,
        )
        .length;
    return '$installed installed    $available available';
  }

  void _renderEmpty(
    StringBuffer buffer,
    String Function(String text, String code) paint,
  ) {
    if (filter.isNotEmpty) {
      buffer.writeln('  ${paint('No packages match "$filter".', '2')}');
      return;
    }
    buffer.writeln(
      '  ${paint(events ? 'No event packs installed.' : 'No plugins installed.', '2')}',
    );
    buffer.writeln();
    buffer.writeln(
      '  ${paint('Nothing is installed just because a file was found.', '2')}',
    );
    buffer.writeln(
      '  ${paint('Press R to read the library. Put a .ayu file in one of these places:', '2')}',
    );
    final roots = desk.inventory.roots;
    if (roots.isEmpty) {
      buffer.writeln('    ${desk.scanner.libraryDirectory.path}');
      final repository = desk.repositoryRoot;
      if (repository != null) {
        buffer.writeln(
          '    ${repository.path}\\event_packs_src\\<name>\\build\\ayu',
        );
        buffer.writeln('    ${repository.path}\\examples\\<name>\\build\\ayu');
      }
      return;
    }
    for (final root in roots) {
      buffer.writeln('    $root');
    }
  }

  void _renderList(
    StringBuffer buffer,
    String Function(String text, String code) paint,
    List<CatalogRow> list,
    CatalogRow? selected,
    int inner,
  ) {
    final start = _windowStart(list, selected, 14);
    final end = (start + 14).clamp(0, list.length);
    for (final row in list.sublist(start, end)) {
      if (!row.selectable) {
        buffer.writeln();
        buffer.writeln('  ${paint(row.title.toUpperCase(), '1')}');
        continue;
      }
      final marker = row.identity == selected?.identity
          ? paint('›', '1;36')
          : ' ';
      final name = _fit(row.title, 22);
      final version = _fit(row.subtitle, 10);
      final badge = _fit(row.badge, inner - 40);
      buffer.writeln('  $marker $name  $version  ${paint(badge, row.tone)}');
    }
  }

  void _renderDetail(
    StringBuffer buffer,
    String Function(String text, String code) paint,
    CatalogRow selected,
    int inner,
  ) {
    final lines = describeSelection(
      inventory: desk.inventory,
      library: selected.library,
      installed: selected.installed,
      failure: selected.failure,
    );
    final window = 16;
    if (detailOffset > lines.length - 1)
      detailOffset = lines.isEmpty ? 0 : lines.length - 1;
    final start = detailOffset.clamp(0, lines.length);
    final slice = lines.skip(start).take(window);
    for (final line in slice) {
      buffer.writeln('  ${_fit(line, inner - 2)}');
    }
    buffer.writeln();
    buffer.writeln(
      '  ${paint('A install+enable    N install only    E enable    D disable', '2')}',
    );
    buffer.writeln(
      '  ${paint('U update    X uninstall    Esc back    Up Down scroll', '2')}',
    );
  }

  int _windowStart(List<CatalogRow> list, CatalogRow? selected, int window) {
    if (list.length <= window) return 0;
    final index = selected == null
        ? 0
        : list.indexWhere((row) => row.identity == selected.identity);
    final origin = index < 0 ? 0 : index;
    return (origin - 4).clamp(0, list.length - window);
  }

  String _fit(String text, int width) {
    final limit = width < 4 ? 4 : width;
    if (text.length <= limit) return text.padRight(limit);
    return '${text.substring(0, limit - 1)}…';
  }
}
