import 'dart:async';
import 'dart:io';

import 'package:toml/toml.dart';

import 'errors.dart';
import 'schema.dart';

/// Reads and watches one `.ayuconf` file. Parsing happens here, not on the
/// server thread that handles Minecraft packets.
final class AyuConfigFile {
  AyuConfigFile({required this.schema, required this.file});

  final AyuConfig schema;
  final File file;

  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _debounce;
  Future<void> Function(ConfigLoadResult result)? _listener;
  var _closed = false;
  var _reading = false;
  var _again = false;

  String state = 'idle';
  String? lastError;

  Future<ConfigLoadResult> load() => _readAndApply();

  /// Writes the schema defaults only when the file does not exist yet.
  Future<ConfigLoadResult> loadOrCreate() async {
    if (!await file.exists()) {
      await writeAyuConf(file, schema.generateDefault());
    }
    return load();
  }

  /// Watches the parent directory. Create, replace, and delete-then-create are all noticed.
  Future<void> watch(Future<void> Function(ConfigLoadResult result) listener) async {
    _listener = listener;
    await _listen();
    state = 'watching';
  }

  Future<void> close() async {
    _closed = true;
    _debounce?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _listen() async {
    await _subscription?.cancel();
    if (_closed) return;
    await file.parent.create(recursive: true);
    _subscription = file.parent.watch(recursive: false).listen(
      (event) {
        if (_name(event.path) != _name(file.path)) return;
        _schedule();
      },
      onError: (Object error) {
        state = 'watcher failed';
        lastError = '$error';
        if (_closed) return;
        unawaited(_listen());
      },
    );
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    if (_reading) {
      _again = true;
      return;
    }
    _reading = true;
    try {
      final result = await _readAndApply();
      final listener = _listener;
      if (listener != null) await listener(result);
    } finally {
      _reading = false;
      if (_again && !_closed) {
        _again = false;
        _schedule();
      }
    }
  }

  Future<ConfigLoadResult> _readAndApply() async {
    state = 'parsing';
    if (!await file.exists()) {
      state = 'rejected';
      lastError = '${file.path} is missing; the previous configuration stays active';
      return ConfigLoadResult(
        applied: false,
        revision: schema.snapshot.revision,
        problems: [ConfigProblem(lastError!)],
        state: 'rejected',
      );
    }
    final String text;
    try {
      text = await _readStable();
    } on Object catch (error) {
      state = 'rejected';
      lastError = 'could not read ${file.path}: $error';
      return ConfigLoadResult(
        applied: false,
        revision: schema.snapshot.revision,
        problems: [ConfigProblem(lastError!)],
        state: 'rejected',
      );
    }
    if (text.length > 1024 * 256) {
      state = 'rejected';
      lastError = '${file.path} is larger than 256 KiB';
      return ConfigLoadResult(
        applied: false,
        revision: schema.snapshot.revision,
        problems: [ConfigProblem(lastError!)],
        state: 'rejected',
      );
    }
    state = 'validating';
    Map<String, Object?> document;
    try {
      document = _asMap(TomlDocument.parse(text).toMap());
    } on Object catch (error) {
      state = 'rejected';
      lastError = 'TOML parse error: $error';
      return ConfigLoadResult(
        applied: false,
        revision: schema.snapshot.revision,
        problems: [ConfigProblem(lastError!)],
        state: 'rejected',
      );
    }
    final ayu = document['ayu'];
    final version = ayu is Map && ayu['schema-version'] is int ? ayu['schema-version'] as int : 1;
    final result = schema.applyDocument(document);
    if (result.applied && version < schema.schemaVersion) {
      final backup = File('${file.path}.bak');
      if (!await backup.exists()) await backup.writeAsString(text, flush: true);
    }
    state = result.state;
    lastError = result.applied ? null : result.summary;
    return result;
  }

  /// Two identical reads mean the writer has finished. A changing file is retried, bounded.
  Future<String> _readStable() async {
    Object? last;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final first = await file.readAsString();
        await Future<void>.delayed(const Duration(milliseconds: 15));
        final second = await file.readAsString();
        if (first == second) return first;
      } on FileSystemException catch (error) {
        last = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw last ?? StateError('file kept changing');
  }
}

String _name(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.split('/').last;
}

Map<String, Object?> _asMap(Map<dynamic, dynamic> raw) => {
  for (final entry in raw.entries) '${entry.key}': _plain(entry.value),
};

Object? _plain(Object? value) {
  if (value is Map) return _asMap(value);
  if (value is List) return [for (final item in value) _plain(item)];
  return value;
}

/// Writes [text] via a temporary file so a crash does not leave a half file as the real one.
Future<void> writeAyuConf(File file, String text) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(text, flush: true);
  if (await file.exists()) {
    final backup = File('${file.path}.bak');
    try {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    } on FileSystemException {
      await file.delete();
    }
  }
  try {
    await temporary.rename(file.path);
  } on FileSystemException {
    await file.writeAsString(text, flush: true);
    if (await temporary.exists()) await temporary.delete();
  }
}
