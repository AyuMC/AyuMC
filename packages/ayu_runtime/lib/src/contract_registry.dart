import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_package/ayu_package.dart';
import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';

/// A contract currently offered by an active event pack.
final class ProvidedContract {
  const ProvidedContract({required this.providerId, required this.spec});

  final String providerId;
  final EventContractSpec spec;
}

/// Diagnostic view of one contract.
final class ContractStatus {
  const ContractStatus({
    required this.id,
    required this.version,
    required this.providerId,
    required this.mode,
    required this.subscribers,
    required this.requiredBy,
    required this.optionalFor,
  });

  final String id;
  final Version? version;
  final String? providerId;
  final DeliveryMode? mode;
  final List<String> subscribers;
  final List<String> requiredBy;
  final List<String> optionalFor;

  bool get isAvailable => providerId != null;
}

/// Knows which contracts exist, who provides them, who declared a need for
/// them and who is subscribed right now. Holds no event implementations.
final class ContractRegistry {
  final Map<String, ProvidedContract> _providers = {};
  final Map<String, Set<String>> _subscribers = {};
  final Map<String, Map<String, ContractRequirement>> _requirements = {};
  final Map<String, Set<String>> _primitiveSubscriptions = {};
  final Map<String, Set<String>> _packsByPrimitive = {};

  // ------------------------------------------------------------ providers

  /// Contracts of [packId] become available. Throws when another active
  /// provider already offers one of them; nothing is registered in that
  /// case.
  void registerProvider(String packId, Iterable<EventContractSpec> contracts) {
    final conflicts = <String>[
      for (final contract in contracts)
        if (_providers[contract.id] case final existing? when existing.providerId != packId)
          '"${contract.id}" is already provided by "${existing.providerId}" ${existing.spec.version}',
    ];
    if (conflicts.isNotEmpty) {
      throw PluginHostException(PluginHostErrorCode.conflict,
          'event pack "$packId" conflicts with active providers', details: conflicts);
    }
    for (final contract in contracts) {
      _providers[contract.id] = ProvidedContract(providerId: packId, spec: contract);
    }
  }

  /// Removes every contract of [packId]; returns the removed contract ids.
  List<String> unregisterProvider(String packId) {
    final removed = <String>[
      for (final entry in _providers.entries)
        if (entry.value.providerId == packId) entry.key,
    ];
    removed.forEach(_providers.remove);
    _primitiveSubscriptions.remove(packId);
    for (final packs in _packsByPrimitive.values) {
      packs.remove(packId);
    }
    _packsByPrimitive.removeWhere((_, packs) => packs.isEmpty);
    return removed;
  }

  ProvidedContract? provider(String contractId) => _providers[contractId];

  Iterable<String> get availableContracts => _providers.keys;

  /// Conflicts an inactive pack would cause if activated now.
  List<String> conflictsFor(String packId, Iterable<EventContractSpec> contracts) => [
        for (final contract in contracts)
          if (_providers[contract.id] case final existing? when existing.providerId != packId)
            '"${contract.id}" is already provided by "${existing.providerId}"',
      ];

  // ------------------------------------------------- primitive interest

  /// An event pack asked to observe [primitiveId]. Refused unless one of its
  /// declared contracts lists the primitive as a source.
  void subscribePrimitive(String packId, String primitiveId, PluginManifest manifest) {
    if (!manifest.primitiveSources.contains(primitiveId)) {
      throw IpcException.code(IpcErrorCode.invalidParams,
          '"$primitiveId" is not a declared source of any contract provided by "$packId"');
    }
    _primitiveSubscriptions.putIfAbsent(packId, () => {}).add(primitiveId);
    _packsByPrimitive.putIfAbsent(primitiveId, () => {}).add(packId);
  }

  bool unsubscribePrimitive(String packId, String primitiveId) {
    final removed = _primitiveSubscriptions[packId]?.remove(primitiveId) ?? false;
    if (!removed) return false;
    final packs = _packsByPrimitive[primitiveId]!..remove(packId);
    if (packs.isEmpty) _packsByPrimitive.remove(primitiveId);
    return true;
  }

  /// Packs that subscribed to [primitiveId].
  Iterable<String> primitiveSubscribers(String primitiveId) => _packsByPrimitive[primitiveId] ?? const <String>{};

  /// Contracts of [packId] fed by [primitiveId].
  Iterable<EventContractSpec> contractsFedBy(String packId, String primitiveId) => [
        for (final provided in _providers.values)
          if (provided.providerId == packId && provided.spec.sources.contains(primitiveId)) provided.spec,
      ];

  /// Whether forwarding [primitiveId] to [packId] does useful work: some
  /// observational contract fed by it has a subscriber. Decision contracts
  /// are consulted through [decisionContractFor] instead.
  bool hasDemand(String packId, String primitiveId) => contractsFedBy(packId, primitiveId).any((contract) =>
      contract.delivery.mode == DeliveryMode.observational && (_subscribers[contract.id]?.isNotEmpty ?? false));

  /// The decision contract of [packId] fed by [primitiveId], if any. Its
  /// budget and timeout policy govern the round.
  EventContractSpec? decisionContractFor(String packId, String primitiveId) =>
      contractsFedBy(packId, primitiveId).where((c) => c.delivery.mode == DeliveryMode.decision).firstOrNull;

  // ------------------------------------------------------------ consumers

  void declareRequirements(String pluginId, Iterable<ContractRequirement> requirements) {
    _requirements[pluginId] = {for (final r in requirements) r.id: r};
  }

  /// A plugin may only subscribe to contracts its manifest declares.
  void subscribe(String pluginId, String contractId) {
    final declared = _requirements[pluginId]?[contractId];
    if (declared == null) {
      throw IpcException.code(IpcErrorCode.capabilityDenied,
          'contract "$contractId" is not declared in the manifest of "$pluginId" (events.requires / events.optional)');
    }
    _subscribers.putIfAbsent(contractId, () => {}).add(pluginId);
  }

  bool unsubscribe(String pluginId, String contractId) {
    final removed = _subscribers[contractId]?.remove(pluginId) ?? false;
    if (removed && _subscribers[contractId]!.isEmpty) _subscribers.remove(contractId);
    return removed;
  }

  /// Forgets subscriptions and declared requirements of [pluginId].
  void removeConsumer(String pluginId) {
    _requirements.remove(pluginId);
    for (final subscribers in _subscribers.values) {
      subscribers.remove(pluginId);
    }
    _subscribers.removeWhere((_, subscribers) => subscribers.isEmpty);
  }

  Iterable<String> subscribers(String contractId) => _subscribers[contractId] ?? const <String>{};

  Set<String> subscriptionsOf(String pluginId) =>
      {for (final e in _subscribers.entries) if (e.value.contains(pluginId)) e.key};

  /// Required contracts of [manifest] that are missing or incompatible.
  List<String> unsatisfiedRequirements(PluginManifest manifest) {
    final problems = <String>[];
    for (final requirement in manifest.requiredEvents) {
      final provided = _providers[requirement.id];
      if (provided == null) {
        problems.add('contract "${requirement.id}" ${requirement.version} has no active provider');
      } else if (!requirement.version.allows(provided.spec.version)) {
        problems.add(
            'contract "${requirement.id}" ${provided.spec.version} (from "${provided.providerId}") does not satisfy ${requirement.version}');
      }
    }
    return problems;
  }

  /// Plugins whose declared *required* contracts include any of [contracts].
  List<String> consumersRequiring(Iterable<String> contracts) {
    final wanted = contracts.toSet();
    return [
      for (final entry in _requirements.entries)
        if (entry.value.values.any((r) => !r.optional && wanted.contains(r.id))) entry.key,
    ];
  }

  /// Plugins that declared any of [contracts] as optional.
  List<String> consumersOptionallyUsing(Iterable<String> contracts) {
    final wanted = contracts.toSet();
    return [
      for (final entry in _requirements.entries)
        if (entry.value.values.any((r) => r.optional && wanted.contains(r.id))) entry.key,
    ];
  }

  /// Diagnostics over every known contract: provided, required or optional.
  List<ContractStatus> describe() {
    final ids = <String>{
      ..._providers.keys,
      for (final reqs in _requirements.values) ...reqs.keys,
    }.toList()
      ..sort();
    return [
      for (final id in ids)
        ContractStatus(
          id: id,
          version: _providers[id]?.spec.version,
          providerId: _providers[id]?.providerId,
          mode: _providers[id]?.spec.delivery.mode,
          subscribers: subscribers(id).toList()..sort(),
          requiredBy: [
            for (final e in _requirements.entries)
              if (e.value[id] case final r? when !r.optional) e.key,
          ]..sort(),
          optionalFor: [
            for (final e in _requirements.entries)
              if (e.value[id] case final r? when r.optional) e.key,
          ]..sort(),
        ),
    ];
  }
}
