import 'errors.dart';
import 'placeholder.dart';

/// Immutable values from one successful load. Read every related option from
/// the same snapshot so a reload cannot mix two versions inside one operation.
final class ConfigSnapshot {
  ConfigSnapshot({
    required this.revision,
    required Map<String, Object?> values,
    required Map<String, ParsedTemplate> templates,
    required Map<String, Placeholder<Object?>> placeholders,
    required Set<String> secrets,
  }) : values = Map.unmodifiable(values),
       templates = Map.unmodifiable(templates),
       placeholders = Map.unmodifiable(placeholders),
       secrets = Set.unmodifiable(secrets);

  static final initial = ConfigSnapshot(
    revision: 0,
    values: const {},
    templates: const {},
    placeholders: const {},
    secrets: const {},
  );

  final int revision;
  final Map<String, Object?> values;
  final Map<String, ParsedTemplate> templates;
  final Map<String, Placeholder<Object?>> placeholders;
  final Set<String> secrets;

  T read<T>(ConfigOption<T> option) {
    final value = values[option.key];
    if (value is! T) {
      throw StateError('configuration ${option.key} is not available as $T');
    }
    return value;
  }

  String render(MessageOption option, PlaceholderContext context) {
    final template = templates[option.key];
    if (template == null) {
      throw StateError('configuration ${option.key} has no message template');
    }
    return template.render(context, placeholders);
  }

  /// Debug view. Secret values are never included.
  Map<String, Object?> redacted() => {
    for (final entry in values.entries)
      entry.key: secrets.contains(entry.key) ? '***' : entry.value,
  };
}

/// One setting. Construct it inside [AyuConfig.define] and keep the object.
abstract class ConfigOption<T> {
  ConfigOption(
    this.key, {
    required this.defaultValue,
    this.description,
    this.required = false,
  });

  final String key;
  final T? defaultValue;
  final String? description;
  final bool required;

  /// Checks [raw]. `missing` means the key was absent.
  T? validate(Object? raw, bool missing, List<ConfigProblem> problems);
}

final class StringOption extends ConfigOption<String> {
  StringOption(
    super.key, {
    required String super.defaultValue,
    super.description,
    super.required,
    this.maxLength = 4096,
    this.secret = false,
  });

  final int maxLength;
  final bool secret;

  @override
  String? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return _missing(problems);
    if (raw is! String) {
      problems.add(ConfigProblem('expected a string', key: key));
      return null;
    }
    if (raw.length > maxLength) {
      problems.add(ConfigProblem('is longer than $maxLength characters', key: key));
      return null;
    }
    return raw;
  }

  String? _missing(List<ConfigProblem> problems) {
    if (required && defaultValue == null) {
      problems.add(ConfigProblem('is required', key: key));
      return null;
    }
    return defaultValue;
  }
}

final class SecretOption extends StringOption {
  SecretOption(super.key, {required super.defaultValue, super.description, super.maxLength})
    : super(secret: true);
}

final class IntOption extends ConfigOption<int> {
  IntOption(
    super.key, {
    required int super.defaultValue,
    super.description,
    this.min,
    this.max,
  });

  final int? min;
  final int? max;

  @override
  int? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return defaultValue;
    if (raw is! int) {
      problems.add(ConfigProblem('expected an integer', key: key));
      return null;
    }
    if (min != null && raw < min!) {
      problems.add(ConfigProblem('must be at least $min', key: key));
      return null;
    }
    if (max != null && raw > max!) {
      problems.add(ConfigProblem('must be at most $max', key: key));
      return null;
    }
    return raw;
  }
}

final class NumOption extends ConfigOption<num> {
  NumOption(super.key, {required num super.defaultValue, super.description, this.min, this.max});

  final num? min;
  final num? max;

  @override
  num? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return defaultValue;
    if (raw is! num) {
      problems.add(ConfigProblem('expected a number', key: key));
      return null;
    }
    if (min != null && raw < min!) {
      problems.add(ConfigProblem('must be at least $min', key: key));
      return null;
    }
    if (max != null && raw > max!) {
      problems.add(ConfigProblem('must be at most $max', key: key));
      return null;
    }
    return raw;
  }
}

final class BoolOption extends ConfigOption<bool> {
  BoolOption(super.key, {required bool super.defaultValue, super.description});

  @override
  bool? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return defaultValue;
    if (raw is! bool) {
      problems.add(ConfigProblem('expected true or false', key: key));
      return null;
    }
    return raw;
  }
}

final class EnumOption<T> extends ConfigOption<T> {
  EnumOption(
    super.key, {
    required this.values,
    required T super.defaultValue,
    super.description,
  });

  final Map<String, T> values;

  @override
  T? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return defaultValue;
    if (raw is! String || !values.containsKey(raw)) {
      problems.add(
        ConfigProblem('expected one of ${values.keys.join(', ')}', key: key),
      );
      return null;
    }
    return values[raw] as T;
  }
}

final class StringListOption extends ConfigOption<List<String>> {
  StringListOption(
    super.key, {
    List<String> super.defaultValue = const [],
    super.description,
    this.maxItems = 256,
    this.maxItemLength = 256,
  });

  final int maxItems;
  final int maxItemLength;

  @override
  List<String>? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    if (missing) return List.unmodifiable(defaultValue ?? const []);
    if (raw is! List) {
      problems.add(ConfigProblem('expected a list of strings', key: key));
      return null;
    }
    if (raw.length > maxItems) {
      problems.add(ConfigProblem('has more than $maxItems items', key: key));
      return null;
    }
    final items = <String>[];
    for (final item in raw) {
      if (item is! String || item.length > maxItemLength) {
        problems.add(ConfigProblem('items must be strings of at most $maxItemLength characters', key: key));
        return null;
      }
      items.add(item);
    }
    return List.unmodifiable(items);
  }
}

/// A message template. Placeholders are checked against [placeholders] when the file loads.
final class MessageOption extends ConfigOption<String> {
  MessageOption(
    super.key, {
    required String super.defaultValue,
    required this.placeholders,
    super.description,
    this.maxLength = 2000,
  });

  final Set<Placeholder<Object?>> placeholders;
  final int maxLength;

  @override
  String? validate(Object? raw, bool missing, List<ConfigProblem> problems) {
    final before = problems.length;
    final text = missing ? defaultValue : raw;
    if (text is! String) {
      problems.add(ConfigProblem('expected a string', key: key));
      return null;
    }
    if (text.length > maxLength) {
      problems.add(ConfigProblem('is longer than $maxLength characters', key: key));
      return null;
    }
    final allowed = {for (final item in placeholders) item.id: item};
    final parsed = ParsedTemplate.parse(text, (message) {
      problems.add(ConfigProblem(message, key: key));
    });
    if (parsed != null) {
      for (final id in parsed.placeholderIds) {
        if (!allowed.containsKey(id)) {
          final known = allowed.keys.map((item) => '{$item}').join(', ');
          problems.add(
            ConfigProblem(
              'unknown placeholder {$id}${known.isEmpty ? '' : '; available: $known'}',
              key: key,
            ),
          );
        }
      }
    }
    return problems.length > before ? null : text;
  }
}

/// Turns an older document into the next schema version.
final class ConfigMigration {
  const ConfigMigration({required this.from, required this.to, required this.apply});

  final int from;
  final int to;
  final Map<String, Object?> Function(Map<String, Object?> document) apply;
}

/// Typed schema. Subclasses assign options from [define], which runs during construction.
abstract class AyuConfig {
  AyuConfig({this.schemaVersion = 1}) {
    define();
    final problems = <ConfigProblem>[];
    _current = _compile(const {}, problems, revision: 0);
    if (problems.isNotEmpty) {
      throw StateError(problems.join('; '));
    }
  }

  final int schemaVersion;
  final List<ConfigOption<Object?>> _options = [];
  final Map<String, ConfigOption<Object?>> _byKey = {};
  ConfigSnapshot _current = ConfigSnapshot.initial;

  /// The active snapshot. It changes only after a valid file is committed.
  ConfigSnapshot get snapshot => _current;

  List<ConfigMigration> get migrations => const [];

  void define();

  /// Extra checks after every option has a value. Default: none.
  List<ConfigProblem> validateSnapshot(ConfigSnapshot snapshot) => const [];

  T add<T extends ConfigOption<Object?>>(T option) {
    if (_byKey.containsKey(option.key)) {
      throw StateError('duplicate configuration key ${option.key}');
    }
    _options.add(option);
    _byKey[option.key] = option;
    return option;
  }

  ConfigLoadResult applyDocument(Map<String, Object?> document, {int? line}) {
    final problems = <ConfigProblem>[];
    final warnings = <String>[];
    final version = _schemaVersion(document, problems);
    if (problems.isNotEmpty) {
      return ConfigLoadResult(applied: false, revision: _current.revision, problems: problems, state: 'rejected');
    }
    var body = document;
    if (version < schemaVersion) {
      final migrated = _migrate(body, version, problems);
      if (migrated == null) {
        return ConfigLoadResult(
          applied: false,
          revision: _current.revision,
          problems: problems,
          state: 'migration failed',
        );
      }
      body = migrated;
    } else if (version > schemaVersion) {
      return ConfigLoadResult(
        applied: false,
        revision: _current.revision,
        problems: [
          ConfigProblem(
            'schema-version $version is newer than this plugin understands ($schemaVersion)',
            key: 'ayu.schema-version',
          ),
        ],
        state: 'rejected',
      );
    }
    _warnUnknown(body, warnings);
    final next = _compile(body, problems, revision: _current.revision + 1);
    if (problems.isNotEmpty) {
      return ConfigLoadResult(applied: false, revision: _current.revision, problems: problems, warnings: warnings, state: 'rejected');
    }
    final extra = validateSnapshot(next);
    if (extra.isNotEmpty) {
      return ConfigLoadResult(applied: false, revision: _current.revision, problems: extra, warnings: warnings, state: 'rejected');
    }
    _current = next;
    return ConfigLoadResult(applied: true, revision: next.revision, warnings: warnings);
  }

  ConfigSnapshot _compile(Map<String, Object?> document, List<ConfigProblem> problems, {required int revision}) {
    final values = <String, Object?>{};
    final templates = <String, ParsedTemplate>{};
    final placeholders = <String, Placeholder<Object?>>{};
    final secrets = <String>{};
    for (final option in _options) {
      final lookup = _lookup(document, option.key);
      final value = option.validate(lookup.value, lookup.missing, problems);
      if (value != null) values[option.key] = value;
      if (option is StringOption && option.secret) secrets.add(option.key);
      if (option is MessageOption && value is String) {
        final parsed = ParsedTemplate.parse(value, (_) {});
        if (parsed != null) {
          templates[option.key] = parsed;
          for (final placeholder in option.placeholders) {
            placeholders[placeholder.id] = placeholder;
          }
        }
      }
    }
    return ConfigSnapshot(
      revision: revision,
      values: values,
      templates: templates,
      placeholders: placeholders,
      secrets: secrets,
    );
  }

  int _schemaVersion(Map<String, Object?> document, List<ConfigProblem> problems) {
    final ayu = document['ayu'];
    if (ayu == null) return 1;
    if (ayu is! Map || ayu['schema-version'] is! int) {
      problems.add(ConfigProblem('ayu.schema-version must be an integer', key: 'ayu.schema-version'));
      return schemaVersion;
    }
    return ayu['schema-version'] as int;
  }

  Map<String, Object?>? _migrate(Map<String, Object?> document, int from, List<ConfigProblem> problems) {
    var version = from;
    var current = document;
    while (version < schemaVersion) {
      final step = migrations.where((item) => item.from == version).firstOrNull;
      if (step == null || step.to != version + 1) {
        problems.add(
          ConfigProblem('no migration from schema $version to ${version + 1}', key: 'ayu.schema-version'),
        );
        return null;
      }
      try {
        current = step.apply(current);
      } catch (error) {
        problems.add(ConfigProblem('migration from $version failed: $error', key: 'ayu.schema-version'));
        return null;
      }
      version = step.to;
    }
    return current;
  }

  void _warnUnknown(Map<String, Object?> document, List<String> warnings) {
    final known = _byKey.keys.toSet();
    void walk(Object? node, String prefix) {
      if (node is! Map) return;
      for (final entry in node.entries) {
        final path = prefix.isEmpty ? '${entry.key}' : '$prefix.${entry.key}';
        if (path == 'ayu' || path.startsWith('ayu.')) continue;
        if (entry.value is Map) {
          walk(entry.value, path);
        } else if (!known.contains(path)) {
          warnings.add('unknown key $path was kept in the file and ignored');
        }
      }
    }
    walk(document, '');
  }

  String generateDefault() {
    final buffer = StringBuffer()
      ..writeln('# AyuConfig schema $schemaVersion. TOML 1.0.')
      ..writeln('# Saving a valid file applies it without restarting the plugin.')
      ..writeln()
      ..writeln('[ayu]')
      ..writeln('schema-version = $schemaVersion');
    final groups = <String, List<ConfigOption<Object?>>>{};
    for (final option in _options) {
      final head = option.key.split('.').first;
      groups.putIfAbsent(head, () => []).add(option);
    }
    for (final group in groups.entries) {
      buffer
        ..writeln()
        ..writeln('[${group.key}]');
      for (final option in group.value) {
        if (option.description != null) buffer.writeln('# ${option.description}');
        final leaf = option.key.split('.').skip(1).join('.');
        buffer.writeln('$leaf = ${_toml(option.defaultValue)}');
      }
    }
    return buffer.toString();
  }
}

final class _Lookup {
  const _Lookup(this.value, this.missing);
  final Object? value;
  final bool missing;
}

_Lookup _lookup(Map<String, Object?> document, String path) {
  Object? current = document;
  for (final part in path.split('.')) {
    if (current is! Map || !current.containsKey(part)) return const _Lookup(null, true);
    current = current[part];
  }
  return _Lookup(current, false);
}

String _toml(Object? value) {
  if (value is String) return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  if (value is bool || value is num) return '$value';
  if (value is List) return '[${value.map(_toml).join(', ')}]';
  return '""';
}
