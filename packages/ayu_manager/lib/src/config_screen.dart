import 'keys.dart';

enum ConfigAction { load, apply, diagnostics, save, message }

/// One request the configuration screen wants the app to perform.
final class ConfigCommand {
  const ConfigCommand.message(this.message)
    : action = ConfigAction.message,
      path = null,
      value = null;

  const ConfigCommand.action(this.action, {this.path, this.value})
    : message = null;

  final ConfigAction action;
  final String? path;
  final int? value;
  final String? message;
}

/// One setting as the engine describes it.
final class ConfigSetting {
  ConfigSetting.fromJson(Map<String, Object?> json)
    : path = json['path'] as String,
      category = json['category'] as String,
      label = json['label'] as String,
      description = json['description'] as String? ?? '',
      kind = json['kind'] as String? ?? 'integer',
      unit = json['unit'] as String? ?? '',
      scope = json['scope'] as String? ?? 'live',
      defaultValue = json['default'] as int? ?? 0,
      min = json['min'] as int?,
      max = json['max'] as int?,
      choices = [
        for (final choice in json['choices'] as List? ?? const []) '$choice',
      ];

  final String path;
  final String category;
  final String label;
  final String description;
  final String kind;
  final String unit;
  final String scope;
  final int defaultValue;
  final int? min;
  final int? max;
  final List<String> choices;

  String get range {
    if (kind == 'choice') return choices.join('/');
    final low = min;
    final high = max;
    if (low == null && high == null) return '';
    if (unit.isEmpty) return '$low..$high';
    return '$low..$high $unit';
  }

  String get scopeLabel => switch (scope) {
    'newConnections' => 'new connections',
    'restart' => 'restart',
    _ => 'live',
  };
}

/// Keyboard-driven configuration center.
///
/// The screen renders exactly what the engine reports: schema, current
/// effective values, revision, and persistence state. It never writes the file
/// or keeps a second copy of a value.
final class ConfigScreen {
  bool loading = false;
  bool loaded = false;
  String? error;
  int revision = 0;
  bool pendingPersistence = false;
  bool writable = true;
  String? configError;
  int? legacyViewChunks;
  String? file;

  List<String> categories = [];
  final List<ConfigSetting> settings = [];
  final Map<String, int> values = {};
  final Map<String, String> statuses = {};
  Map<String, Object?> readOnly = {};
  Map<String, Object?> diagnostics = {};
  bool diagnosticsLoaded = false;

  int categoryIndex = 0;
  int selected = 0;
  bool filtering = false;
  String filter = '';
  bool editing = false;
  String editBuffer = '';
  String? editError;
  bool help = false;
  String notice = '';

  /// Paths the current screen session would like to see persisted. Used only
  /// for the "pending save" hint; the engine owns the real state.
  final Set<String> _pending = {};

  static const diagnosticsCategory = 'Diagnostics';

  List<String> get allCategories => [...categories, diagnosticsCategory];

  bool get onDiagnostics => currentCategory == diagnosticsCategory;

  String get currentCategory {
    if (categories.isEmpty) return diagnosticsCategory;
    final index = categoryIndex.clamp(0, allCategories.length - 1);
    return allCategories[index];
  }

  List<ConfigSetting> get visibleSettings {
    final needle = filter.toLowerCase();
    return [
      for (final setting in settings)
        if (setting.category == currentCategory &&
            (needle.isEmpty ||
                setting.label.toLowerCase().contains(needle) ||
                setting.path.toLowerCase().contains(needle) ||
                setting.description.toLowerCase().contains(needle)))
          setting,
    ];
  }

  ConfigSetting? get selectedSetting {
    if (onDiagnostics) return null;
    final rows = visibleSettings;
    if (rows.isEmpty) return null;
    return rows[selected.clamp(0, rows.length - 1)];
  }

  int get revision0 => revision;

  void loadFrom(Map<String, Object?> schema) {
    loading = false;
    loaded = true;
    error = null;
    revision = schema['revision'] as int? ?? 0;
    pendingPersistence = schema['pendingPersistence'] == true;
    writable = schema['writable'] != false;
    configError = schema['configError'] as String?;
    legacyViewChunks = schema['legacyViewChunks'] as int?;
    file = schema['file'] as String?;
    categories = [
      for (final name in schema['categories'] as List? ?? const []) '$name',
    ];
    settings
      ..clear()
      ..addAll([
        for (final row in schema['specs'] as List? ?? const [])
          if (row is Map) ConfigSetting.fromJson(row.cast<String, Object?>()),
      ]);
    values
      ..clear()
      ..addAll({
        for (final entry
            in (schema['values'] as Map? ?? const {}).cast<String, Object?>().entries)
          if (entry.value is int) entry.key: entry.value as int,
      });
    readOnly = (schema['readOnly'] as Map? ?? const {}).cast<String, Object?>();
    if (categoryIndex >= allCategories.length) categoryIndex = 0;
    selected = 0;
    if (settings.isEmpty) {
      notice = 'The engine reported no settings.';
    }
  }

  void noteApplyResult(Map<String, Object?> applied) {
    final path = applied['path'] as String?;
    final value = applied['value'] as int?;
    if (path == null || value == null) return;
    values[path] = value;
    revision = applied['revision'] as int? ?? revision;
    pendingPersistence = applied['pendingPersistence'] == true;
    final scope = applied['scope'] as String? ?? 'live';
    final changed = applied['changed'] != false;
    final base = switch (scope) {
      'newConnections' => 'applied to new connections',
      'restart' => 'saved; applies on restart',
      _ => 'applied live',
    };
    if (!changed) {
      statuses[path] = 'already $value';
    } else if (pendingPersistence) {
      statuses[path] = '$base, saving…';
      _pending.add(path);
    } else {
      statuses[path] = base;
      _pending.remove(path);
    }
    if (legacyViewChunks != null && path == 'viewChunks' && value == 6) {
      legacyViewChunks = null;
      notice = 'Switched to the balanced default view cap of 6 chunks.';
    }
    notice = statuses[path]!;
    editing = false;
    editBuffer = '';
    editError = null;
  }

  void notePersistence(bool pending) {
    pendingPersistence = pending;
    if (!pending) {
      for (final path in _pending) {
        statuses[path] = statuses[path]!.replaceAll(', saving…', '');
      }
      _pending.clear();
    }
  }

  void noteFailure(String message, {String? path}) {
    loading = false;
    editing = false;
    editError = message;
    if (path != null) {
      statuses[path] = 'failed: $message';
    }
    notice = message;
  }

  void noteSaveResult(String message) {
    notice = message;
    pendingPersistence = false;
  }

  void loadDiagnostics(Map<String, Object?> data) {
    diagnostics = data;
    diagnosticsLoaded = true;
    final schema = data['config'];
    if (schema is Map) loadFrom(schema.cast<String, Object?>());
  }

  bool get busy => loading;

  ConfigCommand? handle(KeyEvent event) {
    if (help) {
      help = false;
      return null;
    }
    if (filtering) return _handleFilter(event);
    if (editing) return _handleEdit(event);
    if (event.key == ManagerKey.up) {
      if (!onDiagnostics && selected > 0) selected--;
      return null;
    }
    if (event.key == ManagerKey.down) {
      if (!onDiagnostics && selected < visibleSettings.length - 1) selected++;
      return null;
    }
    if (event.key == ManagerKey.left) return _moveCategory(-1);
    if (event.key == ManagerKey.right) return _moveCategory(1);
    if (event.key == ManagerKey.enter) return _activate();
    switch (event.text?.toLowerCase()) {
      case '/':
        filtering = true;
        filter = '';
        return null;
      case '+':
      case '=':
        return _adjust(1);
      case '-':
      case '_':
        return _adjust(-1);
      case 'd':
        return _resetSelected();
      case 'm':
        return _migrateLegacyView();
      case 'w':
        return const ConfigCommand.action(ConfigAction.save);
      case 'i':
        return const ConfigCommand.action(ConfigAction.load);
      case 'u':
        return const ConfigCommand.action(ConfigAction.diagnostics);
      case 'h':
        help = true;
        return null;
      case 'r':
        return const ConfigCommand.action(ConfigAction.load);
      default:
        return null;
    }
  }

  ConfigCommand? _moveCategory(int delta) {
    if (allCategories.isEmpty) return null;
    categoryIndex =
        (categoryIndex + delta + allCategories.length) % allCategories.length;
    selected = 0;
    filter = '';
    if (onDiagnostics) {
      return const ConfigCommand.action(ConfigAction.diagnostics);
    }
    return null;
  }

  ConfigCommand? _handleFilter(KeyEvent event) {
    if (event.key == ManagerKey.enter) {
      filtering = false;
      selected = 0;
      return null;
    }
    if (event.key == ManagerKey.escape) {
      filtering = false;
      filter = '';
      selected = 0;
      return null;
    }
    if (event.key == ManagerKey.backspace) {
      if (filter.isNotEmpty) {
        filter = filter.substring(0, filter.length - 1);
      }
      return null;
    }
    final text = event.text;
    if (text != null && filter.length < 32) filter += text;
    selected = 0;
    return null;
  }

  ConfigCommand? _handleEdit(KeyEvent event) {
    if (event.key == ManagerKey.escape) {
      editing = false;
      editBuffer = '';
      editError = null;
      return null;
    }
    if (event.key == ManagerKey.backspace) {
      if (editBuffer.isNotEmpty) {
        editBuffer = editBuffer.substring(0, editBuffer.length - 1);
      }
      return null;
    }
    if (event.key == ManagerKey.enter) return _commitEdit();
    final text = event.text;
    if (text == null) return null;
    if (RegExp(r'^-?\d*$').hasMatch('$editBuffer$text')) {
      editBuffer = '$editBuffer$text';
    }
    return null;
  }

  ConfigCommand? _commitEdit() {
    final setting = selectedSetting;
    if (setting == null) return null;
    final parsed = int.tryParse(editBuffer);
    if (parsed == null) {
      editError = 'Enter a whole number.';
      return null;
    }
    final problem = validate(setting, parsed);
    if (problem != null) {
      editError = problem;
      return null;
    }
    return ConfigCommand.action(
      ConfigAction.apply,
      path: setting.path,
      value: parsed,
    );
  }

  /// Inline validation shared with the app so the engine is not asked to apply
  /// a value the screen already knows is out of range.
  static String? validate(ConfigSetting setting, int value) {
    if (setting.kind == 'choice') {
      if (value < 0 || value >= setting.choices.length) {
        return 'Choose ${setting.choices.join(', ')}.';
      }
      return null;
    }
    if (setting.kind == 'toggle' && value != 0 && value != 1) {
      return 'Use 0 or 1.';
    }
    final low = setting.min;
    final high = setting.max;
    if (low != null && value < low) {
      return 'Minimum is $low${setting.unit.isEmpty ? '' : ' ${setting.unit}'}.';
    }
    if (high != null && value > high) {
      return 'Maximum is $high${setting.unit.isEmpty ? '' : ' ${setting.unit}'}.';
    }
    return null;
  }

  ConfigCommand? _activate() {
    final setting = selectedSetting;
    if (setting == null) {
      if (onDiagnostics) {
        return const ConfigCommand.action(ConfigAction.diagnostics);
      }
      return null;
    }
    if (!writable) {
      return const ConfigCommand.message(
        'Configuration is read-only while the engine cannot parse the file.',
      );
    }
    switch (setting.kind) {
      case 'toggle':
        return _apply(setting, values[setting.path] == 1 ? 0 : 1);
      case 'choice':
        final next = ((values[setting.path] ?? 0) + 1) % setting.choices.length;
        return _apply(setting, next);
      default:
        editing = true;
        editBuffer = '${values[setting.path] ?? setting.defaultValue}';
        editError = null;
        return null;
    }
  }

  ConfigCommand? _adjust(int delta) {
    final setting = selectedSetting;
    if (setting == null) return null;
    if (setting.kind == 'choice') {
      final count = setting.choices.length;
      if (count == 0) return null;
      final next = ((values[setting.path] ?? 0) + delta + count) % count;
      return _apply(setting, next);
    }
    final current = values[setting.path] ?? setting.defaultValue;
    final step = _step(setting);
    return _apply(setting, current + delta * step);
  }

  int _step(ConfigSetting setting) {
    final low = setting.min ?? 0;
    final high = setting.max ?? (setting.defaultValue * 4 + 1024);
    final span = high - low;
    if (span <= 0) return 1;
    if (span <= 16) return 1;
    if (span <= 512) return 8;
    if (span <= 8192) return 64;
    if (span <= 65536) return 256;
    return 1024;
  }

  ConfigCommand? _resetSelected() {
    final setting = selectedSetting;
    if (setting == null) return null;
    return _apply(setting, setting.defaultValue);
  }

  ConfigCommand? _migrateLegacyView() {
    final legacy = legacyViewChunks;
    if (legacy == null) {
      return const ConfigCommand.message(
        'No legacy view-distance default is pending.',
      );
    }
    final setting = _byPath('viewChunks');
    if (setting == null) return null;
    return _apply(setting, setting.defaultValue);
  }

  ConfigSetting? _byPath(String path) {
    for (final setting in settings) {
      if (setting.path == path) return setting;
    }
    return null;
  }

  ConfigCommand? _apply(ConfigSetting setting, int value) {
    if (!writable) {
      return const ConfigCommand.message(
        'Configuration is read-only while the engine cannot parse the file.',
      );
    }
    final problem = validate(setting, value);
    if (problem != null) {
      noteFailure(problem, path: setting.path);
      return null;
    }
    return ConfigCommand.action(
      ConfigAction.apply,
      path: setting.path,
      value: value,
    );
  }

  String formatValue(ConfigSetting setting, int value) {
    if (setting.kind == 'choice') {
      if (value >= 0 && value < setting.choices.length) {
        return setting.choices[value];
      }
      return '$value';
    }
    if (setting.kind == 'toggle') return value == 0 ? 'off' : 'on';
    final unit = setting.unit;
    if (unit.isEmpty) return '$value';
    if (unit == 'bytes') return '$value (${_bytes(value)})';
    if (unit == 'MiB') return '$value MiB';
    return '$value $unit';
  }

  static String _bytes(int value) {
    if (value >= 1024 * 1024) {
      final mib = value / (1024 * 1024);
      return '${mib.toStringAsFixed(mib >= 10 ? 0 : 1)} MiB';
    }
    if (value >= 1024) return '${(value / 1024).round()} KiB';
    return '$value B';
  }

  void render(StringBuffer buffer, String Function(String, String) paint,
      int width) {
    final rule = '─' * (width.clamp(40, 120) - 4);
    buffer
      ..writeln('  ${paint('Configuration', '1')}'
          '  ${paint('engine revision $revision', '2')}'
          '${file == null ? '' : '  ${paint(file!, '2')}'}')
      ..writeln(
        '  ${paint(
          pendingPersistence
              ? 'some values are still being written (W saves now)'
              : 'all changes are persisted',
          pendingPersistence ? '33' : '2',
        )}',
      );
    if (configError != null) {
      buffer.writeln('  ${paint(configError!, '31')}');
    }
    if (legacyViewChunks != null) {
      buffer.writeln(
        '  ${paint(
          'viewChunks is still the legacy default of $legacyViewChunks. '
          'Press M to switch to the balanced default of 6.',
          '1;33',
        )}',
      );
    }
    buffer
      ..writeln()
      ..writeln('  ${_categoryBar(paint)}')
      ..writeln(paint('  $rule', '2'));

    if (!loaded) {
      buffer.writeln(
        '  ${paint('No configuration loaded yet. Start the server (6 Power), then press R.', '2')}',
      );
    } else if (onDiagnostics) {
      _renderDiagnostics(buffer, paint, width);
    } else if (visibleSettings.isEmpty) {
      buffer.writeln(
        '  ${paint(
          filter.isEmpty
              ? 'This category has no settings.'
              : 'Nothing matches “$filter”.',
          '2',
        )}',
      );
    } else {
      _renderSettings(buffer, paint, width);
    }

    buffer
      ..writeln()
      ..writeln(paint('  $rule', '2'));
    if (help) {
      buffer.writeln('  ${paint(_helpText(), '2')}');
    } else if (filtering) {
      buffer.writeln(
        '  ${paint('/ $filter▏', '36')}   ${paint('Enter keep    Esc clear', '2')}',
      );
    } else if (editing) {
      buffer.writeln(
        '  ${paint('value $editBuffer▏', '36')}   '
        '${paint(editError ?? 'Enter apply    Esc cancel', editError == null ? '2' : '31')}',
      );
    } else if (notice.isNotEmpty) {
      buffer.writeln('  ${paint(notice, '36')}');
    } else {
      buffer.writeln('  ${paint(hints, '2')}');
    }
  }

  String _categoryBar(String Function(String, String) paint) => [
    for (final name in allCategories)
      name == currentCategory
          ? paint(' $name ', '30;46')
          : paint(' $name ', '2'),
  ].join(' ');

  void _renderSettings(StringBuffer buffer, String Function(String, String) paint,
      int width) {
    final rows = visibleSettings;
    final start = _windowStart(rows.length, selected, 12);
    for (var i = start; i < rows.length && i < start + 12; i++) {
      final setting = rows[i];
      final value = values[setting.path] ?? setting.defaultValue;
      final status = statuses[setting.path];
      final marker = i == selected ? paint('▸', '1;36') : ' ';
      final label = i == selected
          ? paint(setting.label, '1')
          : setting.label;
      final valueText = paint(formatValue(setting, value), '36');
      final scope = paint('[${setting.scopeLabel}]', 
          setting.scope == 'live' ? '2' : '33');
      buffer.writeln('  $marker $label  $valueText  $scope');
      final detail = StringBuffer(
        '      ${setting.range.isEmpty ? '' : 'range ${setting.range}    '}'
        'default ${setting.defaultValue}${setting.unit.isEmpty ? '' : ' ${setting.unit}'}',
      );
      if (status != null) detail.write('    $status');
      buffer.writeln('      ${paint(detail.toString().trim(), '2')}');
      if (i == selected) {
        for (final line in _wrap(setting.description, width - 8)) {
          buffer.writeln('      ${paint(line, '2')}');
        }
        for (final line in _wrap(setting.path, width - 8)) {
          buffer.writeln('      ${paint(line, '90')}');
        }
      }
    }
    if (rows.length > 12) {
      buffer.writeln(
        '  ${paint('${selected + 1}/${rows.length}', '2')}',
      );
    }
  }

  static int _windowStart(int length, int selected, int window) {
    if (length <= window) return 0;
    var start = selected - window ~/ 2;
    if (start < 0) start = 0;
    if (start + window > length) start = length - window;
    return start;
  }

  void _renderDiagnostics(
    StringBuffer buffer,
    String Function(String, String) paint,
    int width,
  ) {
    if (!diagnosticsLoaded) {
      buffer.writeln(
        '  ${paint('Loading diagnostics…', '2')}',
      );
      return;
    }
    final chunks = (diagnostics['chunks'] as Map? ?? const {})
        .cast<String, Object?>();
    final network = (diagnostics['network'] as Map? ?? const {})
        .cast<String, Object?>();
    final views = diagnostics['views'] as List? ?? const [];
    final workerPlan = diagnostics['workerPlan'];
    final sessions = diagnostics['sessions'];

    buffer
      ..writeln('  ${paint('Chunk pipeline', '1')}')
      ..writeln(
        '  ${_stat('queue', '${chunks['chunkQueue']} chunks / '
            '${_bytes((chunks['chunkQueuedBytes'] as int?) ?? 0)}')}'
        '    ${_stat('wanted', '${chunks['chunkWanted']}')}'
        '    ${_stat('resident', '${chunks['chunkResident']}')}'
        '    ${_stat('in flight', '${chunks['chunkInFlight']}')}',
      )
      ..writeln(
        '  ${_stat('generates', '${chunks['chunkGenerates']}')}'
        '    ${_stat('reads', '${chunks['chunkReads']}')}'
        '    ${_stat('storage hit rate', _percent(chunks['chunkStorageHitRate']))}'
        '    ${_stat('dirty', '${chunks['chunkDirty']}')}',
      )
      ..writeln(
        '  ${_stat('stale results', '${chunks['chunkStaleResults']}')}'
        '    ${_stat('cancelled', '${chunks['chunkCancelled']}')}'
        '    ${_stat('unsent drops', '${chunks['chunkUnsentDrops']}')}'
        '    ${_stat('evictions', '${chunks['chunkEvictions']}')}',
      )
      ..writeln(
        '  ${_stat('worker isolates', '${chunks['chunkWorkerActive']} active, '
            '${chunks['chunkWorkerBusy']} busy')}'
        '    ${_stat('pressure', '${chunks['chunkPressure']}')}'
        '    ${_stat('view cap', '${chunks['chunkViewChunks']}')}',
      );
    if (workerPlan is Map) {
      final plan = workerPlan.cast<String, Object?>();
      buffer.writeln(
        '  ${_stat('worker plan', '${plan['mode']} count=${plan['count']}')}',
      );
    }
    buffer
      ..writeln()
      ..writeln('  ${paint('Latency percentiles (µs)', '1')}')
      ..writeln(
        '  ${_percentiles('request→resident', chunks['chunkResidentLatency'])}',
      )
      ..writeln(
        '  ${_percentiles('queue wait', chunks['chunkQueuedWait'])}',
      )
      ..writeln(
        '  ${_percentiles('storage lookup', chunks['chunkLookupLatency'])}',
      )
      ..writeln(
        '  ${_percentiles('resident→socket', chunks['chunkDeliveryWait'])}',
      )
      ..writeln(
        '  ${_percentiles('probe lateness', null, fallbackMicros:
            (chunks['chunkProbeLateMicros'] as int?) ?? 0)}'
        '    ${_stat('rss', _bytes((chunks['rss'] as int?) ?? 0))}',
      )
      ..writeln()
      ..writeln('  ${paint('Delivery and compression', '1')}')
      ..writeln(
        '  ${_stat('columns sent', '${network['chunkDeliveries']}')}'
        '    ${_stat('bytes', _bytes((network['chunkBytes'] as int?) ?? 0))}'
        '    ${_stat('unloads', '${network['chunkUnloads']}')}'
        '    ${_stat('queued', '${network['chunkQueueDepth']}')}',
      )
      ..writeln(
        '  ${_stat('send slice', _bytes((network['sendSliceBytes'] as int?) ?? 0))}'
        '    ${_stat('interval', '${network['sendIntervalMillis']} ms')}'
        '    ${_stat('global budget', _bytes((network['globalSendBytes'] as int?) ?? 0))}'
        '    ${_stat('compression', _percent(
          _ratio(network['compressionWireBytes'], network['compressionRawBytes']),
        ))}',
      )
      ..writeln()
      ..writeln('  ${paint('Connected views ($sessions sessions)', '1')}');
    if (views.isEmpty) {
      buffer.writeln('  ${paint('No sessions connected.', '2')}');
    }
    for (final row in views) {
      if (row is! Map) continue;
      final view = row.cast<String, Object?>();
      buffer.writeln(
        '  ${paint('${view['name']}', '36')}'
        '  chunk ${view['chunkX']},${view['chunkZ']}'
        '  server cap ${view['serverCap']}'
        '  client asked ${view['clientRequested'] ?? '—'}'
        '  effective ${view['effectiveRadius']}'
        '  pending ${view['pendingChunks']}'
        '  held ${view['heldChunks']}',
      );
    }
    if (readOnly.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('  ${paint('World identity (not hot settings)', '1')}')
        ..writeln(
          '  ${_stat('world', '${readOnly['worldId']}')}'
          '    ${_stat('generator', '${readOnly['generatorId']} v${readOnly['generatorVersion']}')}'
          '    ${_stat('seed', '${readOnly['seed']}')}'
          '    ${_stat('storage', '${readOnly['storage']}')}',
        );
    }
  }

  static String _stat(String label, String value) => '$label $value';

  String _percentiles(
    String label,
    Object? value, {
    int fallbackMicros = 0,
  }) {
    if (value is Map) {
      final map = value.cast<String, Object?>();
      return '$label  p50 ${map['p50']}    p95 ${map['p95']}    p99 ${map['p99']}';
    }
    return '$label  $fallbackMicros';
  }

  static String _percent(Object? ratio) {
    if (ratio is num) {
      if (ratio <= 0) return '0%';
      return '${(ratio * 100).toStringAsFixed(ratio >= 1 ? 0 : 1)}%';
    }
    return '—';
  }

  static Object? _ratio(Object? wire, Object? raw) {
    if (wire is int && raw is int && raw > 0) return wire / raw;
    return null;
  }

  static List<String> _wrap(String text, int width) {
    if (width < 20) width = 20;
    final lines = <String>[];
    final words = text.split(RegExp(r'\s+'));
    var current = StringBuffer();
    for (final word in words) {
      if (current.isEmpty) {
        current.write(word);
        continue;
      }
      if (current.length + 1 + word.length > width) {
        lines.add(current.toString());
        current = StringBuffer(word);
        continue;
      }
      current.write(' $word');
    }
    if (current.isNotEmpty) lines.add(current.toString());
    return lines;
  }

  String get hints =>
      'Up/Down select    Left/Right category    Enter edit/toggle    +/- adjust    '
      'D default    M legacy switch    U diagnostics    W save    / search    H help';

  String _helpText() =>
      'Categories are General, Chunk Streaming, Generation and Workers, Memory '
      'and Storage, Network, Diagnostics. "live" settings change the running '
      'engine; "new connections" settings apply to logins from now on; '
      '"restart" settings are saved and applied on the next start. Values are '
      'validated before they are sent, and the engine re-validates them.';
}
