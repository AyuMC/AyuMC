import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_runtime/ayu_runtime.dart';

import '../ayu_server.dart';

/// Control protocol spoken between the manager isolate and the server engine.
///
/// Movement packets never use this protocol. It carries start, stop, console
/// commands, package operations, status, and log or lifecycle notices.
const engineProtocolVersion = 1;

/// How many control requests may be waiting for a response at once.
const engineMaxInFlight = 8;

/// Entry point for the long-lived server isolate.
///
/// The isolate creates its own sockets, [AyuServer], and plugin workers.
/// None of those objects are sent back to the caller.
void serveEngine(SendPort owner) {
  final incoming = ReceivePort();
  owner.send({
    'v': engineProtocolVersion,
    'kind': 'hello',
    'port': incoming.sendPort,
  });
  LogHub.echo = false;
  LogHub.listeners.add((record) {
    owner.send({
      'v': engineProtocolVersion,
      'kind': 'event',
      'name': 'log',
      'logger': record.loggerName,
      'level': record.level.name,
      'message': record.message,
      'time': record.time.millisecondsSinceEpoch,
    });
  });
  final loop = _EngineLoop(owner);
  incoming.listen((message) {
    loop.enqueue(message);
  });
}

final class _EngineLoop {
  _EngineLoop(this.owner);

  final SendPort owner;
  AyuServer? server;
  StreamSubscription<PluginHostEvent>? _plugins;
  int statusReads = 0;
  Future<void> _tail = Future<void>.value();
  var _open = true;

  void enqueue(Object? message) {
    _tail = _tail.then((_) => _handle(message));
  }

  Future<void> _handle(Object? message) async {
    if (!_open || message is! Map) return;
    final map = message.cast<String, Object?>();
    if (map['v'] != engineProtocolVersion || map['kind'] != 'req') return;
    final id = map['id'];
    final op = map['op'];
    if (id is! int || op is! String) return;
    final args = map['args'] is Map
        ? (map['args'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    try {
      final result = await _dispatch(op, args);
      if (op == 'exit') _open = false;
      _reply(id, ok: true, result: result);
    } catch (error) {
      _reply(id, ok: false, error: _failure(error, args['id'] as String?));
    }
  }

  Future<Object?> _dispatch(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'start':
        return _start(args['root'] as String);
      case 'stop':
        return _stop();
      case 'status':
        statusReads++;
        return _status();
      case 'command':
        final current = _requireServer();
        await current.commands.execute(args['line'] as String);
        return const {'ok': true};
      case 'packages':
        return {'packages': await _packages()};
      case 'install':
        return {
          'package': _view(
            await _requireServer().plugins.install(
              File(args['path'] as String),
              enable: args['enable'] == true,
            ),
          ),
        };
      case 'enable':
        return {
          'package': _view(
            await _requireServer().plugins.enable(args['id'] as String),
          ),
        };
      case 'disable':
        return {
          'package': _view(
            await _requireServer().plugins.disable(
              args['id'] as String,
              cascade: args['cascade'] == true,
            ),
          ),
        };
      case 'update':
        return {
          'package': _view(
            await _requireServer().plugins.update(File(args['path'] as String)),
          ),
        };
      case 'uninstall':
        await _requireServer().plugins.uninstall(
          args['id'] as String,
          cascade: args['cascade'] == true,
        );
        return const {'ok': true};
      case 'config.schema':
        return {'schema': _requireServer().config.describe()};
      case 'config.get':
        return {'schema': _requireServer().config.describe()};
      case 'config.apply':
        final applied = await _requireServer().config.apply(
          path: args['path'] as String,
          value: args['value'] as int,
          expectedRevision: args['revision'] as int?,
        );
        return {
          'applied': applied.toJson(),
          'schema': _requireServer().config.describe(),
        };
      case 'config.save':
        await _requireServer().config.flush();
        return {'schema': _requireServer().config.describe()};
      case 'diagnostics':
        final current = server;
        if (current == null) {
          throw EngineException('server is stopped');
        }
        return current.diagnostics();
      case 'exit':
        await _stop();
        return const {'ok': true};
      default:
        throw EngineException('unknown control operation "$op"');
    }
  }

  Future<Map<String, Object?>> _start(String root) async {
    if (server != null) {
      throw EngineException('server is already running');
    }
    final next = AyuServer(rootDirectory: Directory(root));
    try {
      await next.start();
    } catch (error) {
      try {
        await next.stop();
      } on Object {
        // Startup failed before the server was usable.
      }
      rethrow;
    }
    server = next;
    _plugins = next.plugins.events.listen(_forwardPlugin);
    final bound = next.network != null;
    return {
      'state': bound ? 'running' : 'failed',
      'port': next.network?.port,
      'profileId': next.profile.id,
      'runtimeSdk': next.plugins.runtime?.version.toString(),
      'error': bound
          ? null
          : 'Minecraft listener did not bind. Another process may own the port.',
      'startedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>> _stop() async {
    final current = server;
    server = null;
    await _plugins?.cancel();
    _plugins = null;
    if (current != null) await current.stop();
    return const {'state': 'stopped'};
  }

  Map<String, Object?> _status() {
    final current = server;
    return {
      'state': current == null
          ? 'stopped'
          : (current.network == null ? 'failed' : 'running'),
      'port': current?.network?.port,
      'profileId': current?.profile.id,
      'runtimeSdk': current?.plugins.runtime?.version.toString(),
      'statusReads': statusReads,
      'sessions': current?.network?.sessions.length ?? 0,
      'acceptedMovement': current?.network?.acceptedMovementPackets ?? 0,
      'replicationDeliveries': current?.network?.replicationDeliveries ?? 0,
      'configRevision': current?.config.revision,
      'configPending': current?.config.hasPendingPersistence,
      'configError': current?.config.configError,
      'viewChunks': current?.config.value('viewChunks'),
      'compressionThreshold': current?.config.value('compressionThreshold'),
      'chunkDeliveries': current?.network?.chunkDeliveries ?? 0,
      'chunkQueueDepth': current?.network?.chunkQueueDepth ?? 0,
    };
  }

  AyuServer _requireServer() {
    final current = server;
    if (current == null) throw EngineException('server is stopped');
    return current;
  }

  Future<List<Map<String, Object?>>> _packages() async {
    final current = server;
    if (current == null) return const [];
    final subscribers = <String, Set<String>>{};
    for (final row in current.plugins.contracts.describe()) {
      final provider = row.providerId;
      if (provider == null) continue;
      subscribers.putIfAbsent(provider, () => {}).addAll(row.subscribers);
    }
    return [
      for (final snapshot in current.plugins.plugins)
        _view(snapshot, subscribers[snapshot.id] ?? const {}),
    ];
  }

  Map<String, Object?> _view(
    PluginSnapshot snapshot, [
    Set<String> subscribers = const {},
  ]) {
    return {
      'id': snapshot.id,
      'version': snapshot.version.toString(),
      'state': snapshot.state.name,
      'enabled': snapshot.enabled,
      'lastError': snapshot.lastError,
      'pid': snapshot.pid,
      'droppedEvents': snapshot.droppedEvents,
      'restartCount': snapshot.restartCount,
      'stderrTail': snapshot.stderrTail,
      'configState': snapshot.configState,
      'configRevision': snapshot.configRevision,
      'configSchema': snapshot.configSchema,
      'configError': snapshot.configError,
      'installDirectory': snapshot.installDirectory,
      'dataDirectory': snapshot.dataDirectory,
      'subscribers': subscribers.toList()..sort(),
    };
  }

  void _forwardPlugin(PluginHostEvent event) {
    if (event is PluginStateChanged) {
      owner.send({
        'v': engineProtocolVersion,
        'kind': 'event',
        'name': 'plugin-state',
        'id': event.pluginId,
        'from': event.from.name,
        'to': event.to.name,
        'error': event.error,
      });
    } else if (event is PluginLogged) {
      owner.send({
        'v': engineProtocolVersion,
        'kind': 'event',
        'name': 'plugin-log',
        'id': event.pluginId,
        'level': event.level,
        'message': event.message,
        'time': event.timestamp.millisecondsSinceEpoch,
      });
    }
  }

  Map<String, Object?> _failure(Object error, String? id) {
    final body = _encodeFailure(error);
    final current = server;
    if (id != null && current != null) {
      final snapshot = current.plugins.plugin(id);
      if (snapshot != null) body['package'] = _view(snapshot);
    }
    return body;
  }

  void _reply(int id, {required bool ok, Object? result, Object? error}) {
    owner.send({
      'v': engineProtocolVersion,
      'kind': 'res',
      'id': id,
      if (ok) 'result': result,
      if (!ok) 'error': error,
    });
  }
}

Map<String, Object?> _encodeFailure(Object error) {
  if (error is PluginHostException) {
    return {
      'type': 'plugin',
      'message': error.message,
      'details': error.details,
      'code': error.code.name,
    };
  }
  if (error is EngineException) {
    return {
      'type': 'engine',
      'message': error.message,
      'details': error.details,
    };
  }
  return {'type': 'engine', 'message': '$error', 'details': const <String>[]};
}

/// Failure returned across the control boundary. It is not a live server object.
final class EngineException implements Exception {
  EngineException(this.message, {this.details = const [], this.package});

  final String message;
  final List<String> details;
  final EnginePackage? package;

  @override
  String toString() => message;
}

/// Immutable package view safe to keep in the manager isolate.
final class EnginePackage {
  const EnginePackage({
    required this.id,
    required this.version,
    required this.state,
    required this.enabled,
    required this.lastError,
    required this.pid,
    required this.droppedEvents,
    required this.restartCount,
    required this.stderrTail,
    required this.configState,
    required this.configRevision,
    required this.configSchema,
    required this.configError,
    required this.installDirectory,
    required this.dataDirectory,
    required this.subscribers,
  });

  factory EnginePackage.fromJson(Map<String, Object?> json) {
    return EnginePackage(
      id: json['id'] as String,
      version: json['version'] as String,
      state: PluginState.values.byName(json['state'] as String),
      enabled: json['enabled'] as bool,
      lastError: json['lastError'] as String?,
      pid: json['pid'] as int?,
      droppedEvents: json['droppedEvents'] as int? ?? 0,
      restartCount: json['restartCount'] as int? ?? 0,
      stderrTail: json['stderrTail'] as String? ?? '',
      configState: json['configState'] as String? ?? '',
      configRevision: json['configRevision'] as int? ?? 0,
      configSchema: json['configSchema'] as int?,
      configError: json['configError'] as String?,
      installDirectory: json['installDirectory'] as String,
      dataDirectory: json['dataDirectory'] as String,
      subscribers: [
        for (final name in json['subscribers'] as List? ?? const []) '$name',
      ],
    );
  }

  final String id;
  final String version;
  final PluginState state;
  final bool enabled;
  final String? lastError;
  final int? pid;
  final int droppedEvents;
  final int restartCount;
  final String stderrTail;
  final String configState;
  final int configRevision;
  final int? configSchema;
  final String? configError;
  final String installDirectory;
  final String dataDirectory;
  final List<String> subscribers;
}

/// A lifecycle notice from the engine. Logs also go to [LogHub].
sealed class EngineNotice {
  const EngineNotice();
}

final class EnginePluginStateNotice extends EngineNotice {
  const EnginePluginStateNotice(this.pluginId, this.from, this.to, this.error);

  final String pluginId;
  final String from;
  final String to;
  final String? error;
}

final class EnginePluginLogNotice extends EngineNotice {
  const EnginePluginLogNotice(this.pluginId, this.level, this.message);

  final String pluginId;
  final String level;
  final String message;
}

/// Client for one server-engine isolate.
///
/// The manager keeps this. It never receives a socket, a [AyuServer], or a
/// [PluginHost].
final class EngineLink {
  EngineLink({this.requestTimeout = const Duration(seconds: 20)});

  final Duration requestTimeout;
  final StreamController<EngineNotice> _notices =
      StreamController<EngineNotice>.broadcast();
  final Map<int, Completer<Object?>> _pending = {};
  ReceivePort? _incoming;
  ReceivePort? _errors;
  ReceivePort? _exits;
  SendPort? _commands;
  Isolate? _isolate;
  StreamSubscription<dynamic>? _incomingSub;
  int _nextId = 1;
  Future<Map<String, Object?>>? _statusInFlight;
  var _closed = false;
  final Completer<void> _exited = Completer<void>();

  Stream<EngineNotice> get notices => _notices.stream;
  Future<void> get exited => _exited.future;
  bool get isAlive => _isolate != null && !_closed;

  /// Test hook. Drops the isolate without a clean stop.
  void killForTest() {
    _isolate?.kill(priority: Isolate.immediate);
  }

  int get inFlight => _pending.length;

  Future<void> open() async {
    if (_isolate != null) return;
    final incoming = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    _incoming = incoming;
    _errors = errors;
    _exits = exits;
    final hello = Completer<SendPort>();
    _incomingSub = incoming.listen((message) {
      if (message is Map && message['kind'] == 'hello' && !hello.isCompleted) {
        hello.complete(message['port'] as SendPort);
        return;
      }
      _onMessage(message);
    });
    errors.listen((message) {
      final text = message is List ? message.join('\n') : '$message';
      if (!_notices.isClosed) {
        _notices.add(EnginePluginLogNotice('engine', 'error', text));
      }
    });
    exits.listen((_) {
      _markDead('server isolate exited');
    });
    _isolate = await Isolate.spawn(
      serveEngine,
      incoming.sendPort,
      errorsAreFatal: false,
      onError: errors.sendPort,
      onExit: exits.sendPort,
      debugName: 'ayu-engine',
    );
    _commands = await hello.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          throw EngineException('server isolate did not become ready'),
    );
  }

  Future<Map<String, Object?>> start(String root) {
    return _call('start', {'root': root}).then(_map);
  }

  Future<void> stop() async {
    await _call('stop', {});
  }

  Future<Map<String, Object?>> status() {
    final current = _statusInFlight;
    if (current != null) return current;
    final flight = _call('status', {}).then(_map);
    _statusInFlight = flight;
    return flight.whenComplete(() {
      if (identical(_statusInFlight, flight)) _statusInFlight = null;
    });
  }

  Future<void> command(String line) async {
    await _call('command', {'line': line});
  }

  /// Configuration schema, current values, revision, and pending state.
  Future<Map<String, Object?>> configState() async {
    final result = _map(await _call('config.get', {}));
    return _map(result['schema']);
  }

  /// Applies one validated change. [revision] guards against a concurrent
  /// update from another editor.
  Future<Map<String, Object?>> configApply({
    required String path,
    required int value,
    int? revision,
  }) async {
    final result = _map(
      await _call('config.apply', {
        'path': path,
        'value': value,
        'revision': ?revision,
      }),
    );
    return {
      'applied': _map(result['applied']),
      'schema': _map(result['schema']),
    };
  }

  /// Forces the coalesced configuration write to finish now.
  Future<Map<String, Object?>> configSave() async {
    final result = _map(await _call('config.save', {}));
    return _map(result['schema']);
  }

  /// Read-only runtime diagnostics for the configuration screen.
  Future<Map<String, Object?>> diagnostics() async =>
      _map(await _call('diagnostics', {}));

  Future<List<EnginePackage>> packages() async {
    final result = _map(await _call('packages', {}));
    final rows = result['packages'] as List? ?? const [];
    return [
      for (final row in rows)
        EnginePackage.fromJson((row as Map).cast<String, Object?>()),
    ];
  }

  Future<EnginePackage> installPackage(
    String path, {
    required bool enable,
    String? id,
  }) {
    return _packageCall('install', {
      'path': path,
      'enable': enable,
      'id': ?id,
    });
  }

  Future<EnginePackage> enablePackage(String id) {
    return _packageCall('enable', {'id': id});
  }

  Future<EnginePackage> disablePackage(String id, {required bool cascade}) {
    return _packageCall('disable', {'id': id, 'cascade': cascade});
  }

  Future<EnginePackage> updatePackage(String path, {String? id}) {
    return _packageCall('update', {'path': path, 'id': ?id});
  }

  Future<void> uninstallPackage(String id, {required bool cascade}) async {
    await _call('uninstall', {'id': id, 'cascade': cascade});
  }

  Future<void> dispose() async {
    if (_incoming == null) return;
    final alreadyClosed = _closed;
    _closed = true;
    if (!alreadyClosed && _commands != null && _isolate != null) {
      try {
        await _call('exit', {}).timeout(const Duration(seconds: 5));
      } on Object {
        // The isolate may already be gone.
      }
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    await _incomingSub?.cancel();
    _incoming?.close();
    _incoming = null;
    _errors?.close();
    _errors = null;
    _exits?.close();
    _exits = null;
    _failPending('server isolate disposed');
    if (!_exited.isCompleted) _exited.complete();
    if (!_notices.isClosed) await _notices.close();
  }

  Future<EnginePackage> _packageCall(
    String op,
    Map<String, Object?> args,
  ) async {
    final result = _map(await _call(op, args));
    return EnginePackage.fromJson(
      (result['package'] as Map).cast<String, Object?>(),
    );
  }

  Future<Object?> _call(String op, Map<String, Object?> args) {
    final commands = _commands;
    if (_closed || commands == null) {
      throw EngineException('server isolate is not running');
    }
    if (_pending.length >= engineMaxInFlight) {
      throw EngineException(
        'too many control requests are already in flight ($engineMaxInFlight)',
      );
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    commands.send({
      'v': engineProtocolVersion,
      'kind': 'req',
      'id': id,
      'op': op,
      'args': args,
    });
    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw EngineException('control request "$op" timed out');
      },
    );
  }

  void _onMessage(Object? message) {
    if (message is! Map) return;
    final map = message.cast<String, Object?>();
    if (map['kind'] == 'event') {
      _onEvent(map);
      return;
    }
    if (map['kind'] != 'res') return;
    final id = map['id'];
    if (id is! int) return;
    final pending = _pending.remove(id);
    if (pending == null || pending.isCompleted) return;
    if (map.containsKey('error')) {
      pending.completeError(_exception(map['error']));
    } else {
      pending.complete(map['result']);
    }
  }

  void _onEvent(Map<String, Object?> map) {
    switch (map['name']) {
      case 'log':
        final level = LogLevel.values.byName(map['level'] as String? ?? 'info');
        final record = LogRecord(
          time: DateTime.fromMillisecondsSinceEpoch(map['time'] as int? ?? 0),
          loggerName: map['logger'] as String? ?? 'AyuMC',
          level: level,
          message: map['message'] as String? ?? '',
        );
        LogHub.emit(record);
        if (LogHub.echo) {
          stdout.writeln('[${record.loggerName}] ${record.message}');
        }
        break;
      case 'plugin-state':
        if (!_notices.isClosed) {
          _notices.add(
            EnginePluginStateNotice(
              map['id'] as String? ?? '',
              map['from'] as String? ?? '',
              map['to'] as String? ?? '',
              map['error'] as String?,
            ),
          );
        }
        break;
      case 'plugin-log':
        if (!_notices.isClosed) {
          _notices.add(
            EnginePluginLogNotice(
              map['id'] as String? ?? '',
              map['level'] as String? ?? 'info',
              map['message'] as String? ?? '',
            ),
          );
        }
        break;
    }
  }

  void _markDead(String message) {
    _closed = true;
    _commands = null;
    _failPending(message);
    if (!_exited.isCompleted) _exited.complete();
  }

  void _failPending(String message) {
    final pending = List<Completer<Object?>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(EngineException(message));
      }
    }
  }

  EngineException _exception(Object? error) {
    if (error is! Map) return EngineException('$error');
    final map = error.cast<String, Object?>();
    final package = map['package'];
    return EngineException(
      map['message'] as String? ?? 'control request failed',
      details: [
        for (final line in map['details'] as List? ?? const []) '$line',
      ],
      package: package is Map
          ? EnginePackage.fromJson(package.cast<String, Object?>())
          : null,
    );
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  return const {};
}
