import 'errors.dart';
import 'protocol.dart';

/// Strict JSON field access. Every reader throws [IpcException] with
/// [IpcErrorCode.invalidParams] on a wrong shape so that malformed messages
/// surface as structured errors instead of type errors.
abstract final class JsonFields {
  static Map<String, Object?> object(Object? value, String what) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return value.cast<String, Object?>();
    throw IpcException.code(IpcErrorCode.invalidParams, '$what must be an object');
  }

  static String string(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String) return value;
    throw IpcException.code(IpcErrorCode.invalidParams, '"$key" must be a string');
  }

  static String? optionalString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return value;
    throw IpcException.code(IpcErrorCode.invalidParams, '"$key" must be a string');
  }

  static int integer(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is int) return value;
    throw IpcException.code(IpcErrorCode.invalidParams, '"$key" must be an integer');
  }

  static int? optionalInteger(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is int) return value;
    throw IpcException.code(IpcErrorCode.invalidParams, '"$key" must be an integer');
  }

  static bool boolean(Map<String, Object?> map, String key, {bool? orElse}) {
    final value = map[key];
    if (value is bool) return value;
    if (value == null && orElse != null) return orElse;
    throw IpcException.code(IpcErrorCode.invalidParams, '"$key" must be a boolean');
  }

  static List<String> stringList(Map<String, Object?> map, String key,
      {bool optional = false}) {
    final value = map[key];
    if (value == null && optional) return const [];
    if (value is List && value.every((e) => e is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw IpcException.code(
        IpcErrorCode.invalidParams, '"$key" must be a list of strings');
  }

  static List<int> intList(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is List && value.every((e) => e is int)) {
      return List<int>.unmodifiable(value.cast<int>());
    }
    throw IpcException.code(
        IpcErrorCode.invalidParams, '"$key" must be a list of integers');
  }

  static Map<String, Object?> optionalObject(
      Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return const {};
    return object(value, '"$key"');
  }
}

/// First message, sent by the worker as a request.
final class HelloRequest {
  const HelloRequest({
    required this.protocolVersions,
    required this.sdkVersion,
    required this.dartVersion,
    required this.pid,
  });

  factory HelloRequest.fromJson(Object? json) {
    final map = JsonFields.object(json, 'hello');
    return HelloRequest(
      protocolVersions: JsonFields.intList(map, 'protocolVersions'),
      sdkVersion: JsonFields.string(map, 'sdkVersion'),
      dartVersion: JsonFields.string(map, 'dartVersion'),
      pid: JsonFields.integer(map, 'pid'),
    );
  }

  final List<int> protocolVersions;

  /// Version of `ayu_plugin_api` the worker was compiled against.
  final String sdkVersion;

  /// `Platform.version` of the worker.
  final String dartVersion;
  final int pid;

  Map<String, Object?> toJson() => {
    'protocolVersions': protocolVersions,
    'sdkVersion': sdkVersion,
    'dartVersion': dartVersion,
    'pid': pid,
  };
}

final class HelloResponse {
  const HelloResponse({
    required this.protocolVersion,
    required this.hostVersion,
    required this.apiVersion,
    required this.maxFrameBytes,
  });

  factory HelloResponse.fromJson(Object? json) {
    final map = JsonFields.object(json, 'hello response');
    return HelloResponse(
      protocolVersion: JsonFields.integer(map, 'protocolVersion'),
      hostVersion: JsonFields.string(map, 'hostVersion'),
      apiVersion: JsonFields.string(map, 'apiVersion'),
      maxFrameBytes: JsonFields.integer(map, 'maxFrameBytes'),
    );
  }

  final int protocolVersion;
  final String hostVersion;
  final String apiVersion;
  final int maxFrameBytes;

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'hostVersion': hostVersion,
    'apiVersion': apiVersion,
    'maxFrameBytes': maxFrameBytes,
  };
}

/// Identity of a plugin as seen by the worker.
final class PluginDescriptor {
  const PluginDescriptor({
    required this.id,
    required this.name,
    required this.version,
  });

  factory PluginDescriptor.fromJson(Object? json) {
    final map = JsonFields.object(json, 'plugin');
    return PluginDescriptor(
      id: JsonFields.string(map, 'id'),
      name: JsonFields.string(map, 'name'),
      version: JsonFields.string(map, 'version'),
    );
  }

  final String id;
  final String name;
  final String version;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'version': version};
}

/// Sent by the host once the hello handshake succeeded. The worker runs the
/// plugin's `onEnable` before answering.
final class InitRequest {
  const InitRequest({
    required this.plugin,
    required this.installDirectory,
    required this.dataDirectory,
    required this.capabilities,
    required this.config,
  });

  factory InitRequest.fromJson(Object? json) {
    final map = JsonFields.object(json, 'init');
    return InitRequest(
      plugin: PluginDescriptor.fromJson(map['plugin']),
      installDirectory: JsonFields.string(map, 'installDirectory'),
      dataDirectory: JsonFields.string(map, 'dataDirectory'),
      capabilities: JsonFields.stringList(map, 'capabilities'),
      config: JsonFields.optionalObject(map, 'config'),
    );
  }

  final PluginDescriptor plugin;
  final String installDirectory;
  final String dataDirectory;
  final List<String> capabilities;
  final Map<String, Object?> config;

  Map<String, Object?> toJson() => {
    'plugin': plugin.toJson(),
    'installDirectory': installDirectory,
    'dataDirectory': dataDirectory,
    'capabilities': capabilities,
    'config': config,
  };
}

final class ShutdownRequest {
  const ShutdownRequest({required this.reason, required this.graceMillis});

  factory ShutdownRequest.fromJson(Object? json) {
    final map = JsonFields.object(json, 'shutdown');
    return ShutdownRequest(
      reason: JsonFields.string(map, 'reason'),
      graceMillis: JsonFields.integer(map, 'graceMillis'),
    );
  }

  final String reason;

  /// Time the worker has to finish `onDisable` before it is killed.
  final int graceMillis;

  Map<String, Object?> toJson() => {'reason': reason, 'graceMillis': graceMillis};
}

final class LogNotification {
  const LogNotification({
    required this.level,
    required this.message,
    this.timestampMillis,
  });

  factory LogNotification.fromJson(Object? json) {
    final map = JsonFields.object(json, 'log');
    final level = JsonFields.string(map, 'level');
    if (!IpcLogLevel.all.contains(level)) {
      throw IpcException.code(
          IpcErrorCode.invalidParams, 'unknown log level "$level"');
    }
    return LogNotification(
      level: level,
      message: JsonFields.string(map, 'message'),
      timestampMillis: JsonFields.optionalInteger(map, 'ts'),
    );
  }

  final String level;
  final String message;
  final int? timestampMillis;

  Map<String, Object?> toJson() => {
    'level': level,
    'message': message,
    if (timestampMillis != null) 'ts': timestampMillis,
  };
}

/// A command a plugin wants to own.
final class CommandSpec {
  CommandSpec({
    required this.name,
    this.description,
    this.usage,
    List<String> aliases = const [],
  }) : aliases = List.unmodifiable(aliases);

  factory CommandSpec.fromJson(Object? json) {
    final map = JsonFields.object(json, 'command');
    return CommandSpec(
      name: JsonFields.string(map, 'name'),
      description: JsonFields.optionalString(map, 'description'),
      usage: JsonFields.optionalString(map, 'usage'),
      aliases: JsonFields.stringList(map, 'aliases', optional: true),
    );
  }

  final String name;
  final String? description;
  final String? usage;
  final List<String> aliases;

  Map<String, Object?> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (usage != null) 'usage': usage,
    if (aliases.isNotEmpty) 'aliases': aliases,
  };
}

/// Host -> worker: execute a command the worker registered.
final class CommandInvocation {
  CommandInvocation({
    required this.name,
    required List<String> args,
    required this.sender,
  }) : args = List.unmodifiable(args);

  factory CommandInvocation.fromJson(Object? json) {
    final map = JsonFields.object(json, 'command invocation');
    return CommandInvocation(
      name: JsonFields.string(map, 'name'),
      args: JsonFields.stringList(map, 'args', optional: true),
      sender: JsonFields.string(map, 'sender'),
    );
  }

  /// Registered name (never an alias; the host resolves aliases).
  final String name;
  final List<String> args;

  /// Opaque sender identifier such as `console` or `player:<uuid>`.
  final String sender;

  Map<String, Object?> toJson() => {'name': name, 'args': args, 'sender': sender};
}

final class CommandResult {
  const CommandResult({required this.success, this.message});

  const CommandResult.ok([this.message]) : success = true;

  const CommandResult.failure(this.message) : success = false;

  factory CommandResult.fromJson(Object? json) {
    final map = JsonFields.object(json, 'command result');
    return CommandResult(
      success: JsonFields.boolean(map, 'success'),
      message: JsonFields.optionalString(map, 'message'),
    );
  }

  final bool success;
  final String? message;

  Map<String, Object?> toJson() => {
    'success': success,
    if (message != null) 'message': message,
  };
}

/// Host -> worker event notification.
final class EventEnvelope {
  const EventEnvelope({
    required this.type,
    required this.data,
    required this.timestampMillis,
  });

  factory EventEnvelope.fromJson(Object? json) {
    final map = JsonFields.object(json, 'event');
    return EventEnvelope(
      type: JsonFields.string(map, 'type'),
      data: JsonFields.optionalObject(map, 'data'),
      timestampMillis: JsonFields.integer(map, 'ts'),
    );
  }

  final String type;
  final Map<String, Object?> data;
  final int timestampMillis;

  Map<String, Object?> toJson() => {'type': type, 'data': data, 'ts': timestampMillis};
}

/// Worker -> host (un)subscribe parameters.
final class EventSubscriptionSpec {
  const EventSubscriptionSpec(this.type);

  factory EventSubscriptionSpec.fromJson(Object? json) {
    final map = JsonFields.object(json, 'subscription');
    return EventSubscriptionSpec(JsonFields.string(map, 'type'));
  }

  final String type;

  Map<String, Object?> toJson() => {'type': type};
}

/// Several events in one frame (host -> plugin).
final class EventBatch {
  EventBatch(List<EventEnvelope> items) : items = List.unmodifiable(items);

  factory EventBatch.fromJson(Object? json) {
    final map = JsonFields.object(json, 'event batch');
    final raw = map['items'];
    if (raw is! List) throw IpcException.code(IpcErrorCode.invalidParams, '"items" must be a list');
    return EventBatch([for (final item in raw) EventEnvelope.fromJson(item)]);
  }

  final List<EventEnvelope> items;

  Map<String, Object?> toJson() => {'items': [for (final e in items) e.toJson()]};
}

/// An internal primitive observation (host -> event pack).
final class PrimitiveEnvelope {
  const PrimitiveEnvelope({required this.id, required this.data, required this.timestampMillis});

  factory PrimitiveEnvelope.fromJson(Object? json) {
    final map = JsonFields.object(json, 'primitive');
    return PrimitiveEnvelope(
      id: JsonFields.string(map, 'id'),
      data: JsonFields.optionalObject(map, 'data'),
      timestampMillis: JsonFields.integer(map, 'ts'),
    );
  }

  final String id;
  final Map<String, Object?> data;
  final int timestampMillis;

  Map<String, Object?> toJson() => {'id': id, 'data': data, 'ts': timestampMillis};
}

final class PrimitiveBatch {
  PrimitiveBatch(List<PrimitiveEnvelope> items) : items = List.unmodifiable(items);

  factory PrimitiveBatch.fromJson(Object? json) {
    final map = JsonFields.object(json, 'primitive batch');
    final raw = map['items'];
    if (raw is! List) throw IpcException.code(IpcErrorCode.invalidParams, '"items" must be a list');
    return PrimitiveBatch([for (final item in raw) PrimitiveEnvelope.fromJson(item)]);
  }

  final List<PrimitiveEnvelope> items;

  Map<String, Object?> toJson() => {'items': [for (final p in items) p.toJson()]};
}

/// Event pack -> host: a contract event. [timestampMillis] defaults to the
/// host's receive time when omitted.
final class PublishedEvent {
  const PublishedEvent({required this.contract, required this.data, this.timestampMillis});

  factory PublishedEvent.fromJson(Object? json) {
    final map = JsonFields.object(json, 'published event');
    return PublishedEvent(
      contract: JsonFields.string(map, 'contract'),
      data: JsonFields.optionalObject(map, 'data'),
      timestampMillis: JsonFields.optionalInteger(map, 'ts'),
    );
  }

  final String contract;
  final Map<String, Object?> data;
  final int? timestampMillis;

  Map<String, Object?> toJson() => {
    'contract': contract,
    'data': data,
    if (timestampMillis != null) 'ts': timestampMillis,
  };
}

final class PublishedEventBatch {
  PublishedEventBatch(List<PublishedEvent> items) : items = List.unmodifiable(items);

  factory PublishedEventBatch.fromJson(Object? json) {
    final map = JsonFields.object(json, 'published batch');
    final raw = map['items'];
    if (raw is! List) throw IpcException.code(IpcErrorCode.invalidParams, '"items" must be a list');
    return PublishedEventBatch([for (final item in raw) PublishedEvent.fromJson(item)]);
  }

  final List<PublishedEvent> items;

  Map<String, Object?> toJson() => {'items': [for (final e in items) e.toJson()]};
}

/// A decision awaiting a verdict. Used for host -> pack
/// (`primitive.decide`, [id] is a primitive) and host -> plugin
/// (`event.decide`, [id] is a contract).
final class DecisionRequest {
  const DecisionRequest({required this.id, required this.data, required this.budgetMillis});

  factory DecisionRequest.fromJson(Object? json) {
    final map = JsonFields.object(json, 'decision');
    return DecisionRequest(
      id: JsonFields.string(map, 'id'),
      data: JsonFields.optionalObject(map, 'data'),
      budgetMillis: JsonFields.integer(map, 'budgetMs'),
    );
  }

  final String id;
  final Map<String, Object?> data;

  /// Time left for the whole decision when the request was sent.
  final int budgetMillis;

  Map<String, Object?> toJson() => {'id': id, 'data': data, 'budgetMs': budgetMillis};
}

/// Answer to a [DecisionRequest].
///
/// A plugin answers with a [verdict]. An event pack answers either with a
/// verdict (veto / pass-through without consulting consumers) or with a
/// translated [contract] + [data] for the host to put to the consumers.
final class DecisionResponse {
  const DecisionResponse.verdict(this.verdict, {this.reason})
      : contract = null,
        data = null;

  const DecisionResponse.translate(String this.contract, Map<String, Object?> this.data)
      : verdict = null,
        reason = null;

  factory DecisionResponse.fromJson(Object? json) {
    final map = JsonFields.object(json, 'decision response');
    final verdict = JsonFields.optionalString(map, 'verdict');
    final contract = JsonFields.optionalString(map, 'contract');
    if (verdict != null) {
      if (!Verdict.all.contains(verdict)) {
        throw IpcException.code(IpcErrorCode.invalidParams, 'unknown verdict "$verdict"');
      }
      return DecisionResponse.verdict(verdict, reason: JsonFields.optionalString(map, 'reason'));
    }
    if (contract != null) {
      return DecisionResponse.translate(contract, JsonFields.optionalObject(map, 'data'));
    }
    throw IpcException.code(IpcErrorCode.invalidParams, 'decision response needs "verdict" or "contract"');
  }

  final String? verdict;
  final String? reason;
  final String? contract;
  final Map<String, Object?>? data;

  bool get isDeny => verdict == Verdict.deny;

  Map<String, Object?> toJson() => {
    if (verdict != null) 'verdict': verdict,
    if (reason != null) 'reason': reason,
    if (contract != null) 'contract': contract,
    if (data != null) 'data': data,
  };
}

/// Host -> plugin: an optional contract became (un)available.
final class ContractAvailability {
  const ContractAvailability({required this.id, required this.available, this.version});

  factory ContractAvailability.fromJson(Object? json) {
    final map = JsonFields.object(json, 'contract availability');
    return ContractAvailability(
      id: JsonFields.string(map, 'id'),
      available: JsonFields.boolean(map, 'available'),
      version: JsonFields.optionalString(map, 'version'),
    );
  }

  final String id;
  final bool available;
  final String? version;

  Map<String, Object?> toJson() => {'id': id, 'available': available, if (version != null) 'version': version};
}

/// Host -> plugin: [dropped] events of [type] were not delivered.
final class DeliveryGap {
  const DeliveryGap({required this.type, required this.dropped});

  factory DeliveryGap.fromJson(Object? json) {
    final map = JsonFields.object(json, 'delivery gap');
    return DeliveryGap(type: JsonFields.string(map, 'type'), dropped: JsonFields.integer(map, 'dropped'));
  }

  final String type;
  final int dropped;

  Map<String, Object?> toJson() => {'type': type, 'dropped': dropped};
}

/// Event pack -> host (un)subscribe to an internal primitive.
final class PrimitiveSubscriptionSpec {
  const PrimitiveSubscriptionSpec(this.id);

  factory PrimitiveSubscriptionSpec.fromJson(Object? json) {
    final map = JsonFields.object(json, 'primitive subscription');
    return PrimitiveSubscriptionSpec(JsonFields.string(map, 'id'));
  }

  final String id;

  Map<String, Object?> toJson() => {'id': id};
}

/// Worker -> host unregister parameters.
final class CommandNameSpec {
  const CommandNameSpec(this.name);

  factory CommandNameSpec.fromJson(Object? json) {
    final map = JsonFields.object(json, 'command name');
    return CommandNameSpec(JsonFields.string(map, 'name'));
  }

  final String name;

  Map<String, Object?> toJson() => {'name': name};
}
