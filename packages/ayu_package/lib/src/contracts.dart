import 'package:pub_semver/pub_semver.dart';

/// What a package is. Both kinds share the `.ayu` format and the worker
/// runtime; the host treats them differently.
enum PackageType {
  /// Consumes event contracts and host capabilities.
  plugin('plugin'),

  /// Observes internal primitives and provides event contracts.
  eventPack('event-pack');

  const PackageType(this.wireName);

  final String wireName;

  static PackageType? fromWire(String? value) =>
      values.where((t) => t.wireName == value).firstOrNull;
}

/// How events of a contract reach consumers.
enum DeliveryMode {
  /// One-way notification; the originating operation never waits.
  observational,

  /// The originating operation waits, within a budget, for a verdict.
  decision,
}

/// Behaviour when a consumer's bounded queue is full.
enum OverflowPolicy {
  /// Drop the oldest queued events for that consumer and emit a
  /// `delivery.gap` marker with the count. Nothing is dropped silently.
  gap,

  /// Keep only the newest event per [DeliverySpec.coalesceKey]; legal only
  /// when the contract says the latest value supersedes earlier ones.
  coalesce,
}

/// Verdict applied when no decision arrives within the budget.
enum TimeoutPolicy { allow, deny }

/// Delivery semantics of one contract. Declared by the provider; the
/// dispatcher applies exactly these optimisations and no others.
final class DeliverySpec {
  const DeliverySpec({
    this.mode = DeliveryMode.observational,
    this.batching = true,
    this.overflow = OverflowPolicy.gap,
    this.coalesceKey,
    this.onTimeout = TimeoutPolicy.allow,
    this.budget = const Duration(milliseconds: 200),
    this.queueLimit = 4096,
  });

  final DeliveryMode mode;

  /// Whether several events may travel in one frame.
  final bool batching;
  final OverflowPolicy overflow;

  /// Payload field identifying the entity whose newer events supersede
  /// older ones. Required when [overflow] is [OverflowPolicy.coalesce].
  final String? coalesceKey;

  /// Decision contracts only.
  final TimeoutPolicy onTimeout;
  final Duration budget;

  /// Maximum queued events per consumer before [overflow] applies.
  final int queueLimit;

  static DeliverySpec? fromJson(Object? json, void Function(String) problem) {
    if (json == null) return const DeliverySpec();
    if (json is! Map) {
      problem('must be an object');
      return null;
    }
    final map = json.cast<String, Object?>();
    var ok = true;
    final modeName = map['mode'] ?? 'observational';
    final mode = DeliveryMode.values.where((m) => m.name == modeName).firstOrNull;
    if (mode == null) {
      problem('mode: unknown "$modeName"');
      ok = false;
    }
    final overflowName = map['overflow'] ?? 'gap';
    final overflow = OverflowPolicy.values.where((o) => o.name == overflowName).firstOrNull;
    if (overflow == null) {
      problem('overflow: unknown "$overflowName"');
      ok = false;
    }
    final timeoutName = map['onTimeout'] ?? 'allow';
    final onTimeout = TimeoutPolicy.values.where((t) => t.name == timeoutName).firstOrNull;
    if (onTimeout == null) {
      problem('onTimeout: unknown "$timeoutName"');
      ok = false;
    }
    final batching = map['batching'] ?? true;
    if (batching is! bool) {
      problem('batching: must be a boolean');
      ok = false;
    }
    final coalesceKey = map['coalesceKey'];
    if (coalesceKey != null && coalesceKey is! String) {
      problem('coalesceKey: must be a string');
      ok = false;
    }
    if (overflow == OverflowPolicy.coalesce && coalesceKey == null) {
      problem('coalesceKey: required when overflow is "coalesce"');
      ok = false;
    }
    final budgetMs = map['budgetMs'] ?? 200;
    if (budgetMs is! int || budgetMs <= 0 || budgetMs > 60000) {
      problem('budgetMs: must be an integer between 1 and 60000');
      ok = false;
    }
    final queueLimit = map['queueLimit'] ?? 4096;
    if (queueLimit is! int || queueLimit < 1 || queueLimit > 1 << 20) {
      problem('queueLimit: must be an integer between 1 and ${1 << 20}');
      ok = false;
    }
    if (!ok) return null;
    return DeliverySpec(
      mode: mode!,
      batching: batching as bool,
      overflow: overflow!,
      coalesceKey: coalesceKey as String?,
      onTimeout: onTimeout!,
      budget: Duration(milliseconds: budgetMs as int),
      queueLimit: queueLimit as int,
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'batching': batching,
    'overflow': overflow.name,
    if (coalesceKey != null) 'coalesceKey': coalesceKey,
    if (mode == DeliveryMode.decision) 'onTimeout': onTimeout.name,
    if (mode == DeliveryMode.decision) 'budgetMs': budget.inMilliseconds,
    'queueLimit': queueLimit,
  };
}

/// An event contract an event pack provides.
final class EventContractSpec {
  EventContractSpec({
    required this.id,
    required this.version,
    required this.delivery,
    List<String> sources = const [],
    Map<String, String> schema = const {},
    this.description,
  })  : sources = List.unmodifiable(sources),
        schema = Map.unmodifiable(schema);

  /// Dot-separated identifier such as `player.joined`.
  final String id;
  final Version version;
  final DeliverySpec delivery;

  /// Internal primitives the provider needs to produce this contract. The
  /// host forwards a primitive to the pack only while a contract fed by it
  /// has consumers.
  final List<String> sources;

  /// Payload field -> type name (`string`, `int`, `double`, `bool`,
  /// `object`, `list`). Documentation and light validation.
  final Map<String, String> schema;
  final String? description;

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version.toString(),
    'delivery': delivery.toJson(),
    if (sources.isNotEmpty) 'sources': sources,
    if (schema.isNotEmpty) 'schema': schema,
    if (description != null) 'description': description,
  };
}

/// A contract a plugin consumes.
final class ContractRequirement {
  const ContractRequirement({required this.id, required this.version, this.optional = false});

  final String id;
  final VersionConstraint version;
  final bool optional;

  Map<String, Object?> toJson() => {'id': id, 'version': version.toString()};
}

/// Naming rules shared by contracts and internal primitives.
abstract final class ContractNaming {
  /// `namespace.name` with at least one dot; lowercase identifiers.
  static final RegExp contractIdPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

  /// Internal primitives always live under the `core.` namespace so they can
  /// never be mistaken for public contracts.
  static const primitivePrefix = 'core.';

  static bool isPrimitive(String id) => id.startsWith(primitivePrefix);

  static const schemaTypes = <String>{'string', 'int', 'double', 'bool', 'object', 'list'};
}
