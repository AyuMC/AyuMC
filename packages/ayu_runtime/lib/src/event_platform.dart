import 'dart:async';

import 'package:ayu_ipc/ayu_ipc.dart';
import 'package:ayu_logging/ayu_logging.dart';
import 'package:ayu_package/ayu_package.dart';

import 'contract_registry.dart';
import 'plugin_instance.dart';
import 'plugin_state.dart';
import 'runtime_options.dart';
import 'worker_outbox.dart';

/// Result of a decision round.
final class DecisionOutcome {
  const DecisionOutcome._(this.allowed, this.reason, this.timedOut);

  const DecisionOutcome.allow() : this._(true, null, false);

  const DecisionOutcome.deny([String? reason]) : this._(false, reason, false);

  const DecisionOutcome.timeout(TimeoutPolicy policy)
    : this._(policy == TimeoutPolicy.allow, 'decision budget exhausted', true);

  final bool allowed;
  final String? reason;
  final bool timedOut;

  @override
  String toString() =>
      '${allowed ? 'allow' : 'deny'}${reason == null ? '' : ' ($reason)'}';
}

/// Routes contract events from providers to consumers and consults
/// consumers on decision contracts. Owns one bounded outbox per consumer.
final class EventDispatcher {
  EventDispatcher({
    required this.registry,
    required this.options,
    required Logger log,
    required PluginInstance? Function(String id) lookup,
  }) : _log = log,
       _lookup = lookup;

  final ContractRegistry registry;
  final PluginRuntimeOptions options;
  final Logger _log;
  final PluginInstance? Function(String id) _lookup;
  final Map<String, WorkerOutbox> _outboxes = {};
  int rejectedPublishes = 0;

  /// Creates the consumer's outbox; call when its worker becomes active.
  void attach(PluginInstance consumer) {
    final worker = consumer.worker;
    if (worker == null) return;
    _outboxes[consumer.id]?.close();
    _outboxes[consumer.id] = WorkerOutbox(
      send: (method, params) => worker.channel.notify(method, params),
      singleMethod: IpcMethod.event,
      batchMethod: IpcMethod.eventBatch,
      maxBatchItems: options.maxBatchItems,
      onGap: (type, dropped) {
        consumer.droppedEvents += dropped;
        worker.channel.notify(
          IpcMethod.deliveryGap,
          DeliveryGap(type: type, dropped: dropped).toJson(),
        );
        _log.warn(
          '[${consumer.id}] dropped $dropped event(s) of "$type" (queue full)',
        );
      },
    );
  }

  void detach(String consumerId) => _outboxes.remove(consumerId)?.close();

  /// Delivers [event] published by [providerId] to the contract's live
  /// subscribers. Returns how many consumers received it.
  int publish(String providerId, PublishedEvent event) {
    final provided = registry.provider(event.contract);
    if (provided == null || provided.providerId != providerId) {
      rejectedPublishes++;
      _log.warn(
        '[$providerId] published "${event.contract}", which it does not provide; ignored',
      );
      return 0;
    }
    final subscribers = registry.subscribers(event.contract);
    if (subscribers.isEmpty) return 0;
    final envelope = EventEnvelope(
      type: event.contract,
      data: event.data,
      timestampMillis:
          event.timestampMillis ?? DateTime.now().millisecondsSinceEpoch,
    ).toJson();
    var delivered = 0;
    for (final id in subscribers) {
      final outbox = _outboxes[id];
      final consumer = _lookup(id);
      if (outbox == null ||
          consumer == null ||
          consumer.state != PluginState.active) {
        continue;
      }
      outbox.enqueue(event.contract, provided.spec.delivery, envelope);
      delivered++;
    }
    return delivered;
  }

  /// Consults every active subscriber of a decision contract in parallel
  /// within [budget]. Any deny wins; a consumer that fails or times out is
  /// judged by the contract's timeout policy.
  Future<DecisionOutcome> decide(
    EventContractSpec contract,
    Map<String, Object?> data,
    Duration budget,
  ) async {
    final subscribers = [
      for (final id in registry.subscribers(contract.id))
        if (_lookup(id) case final consumer?
            when consumer.state == PluginState.active &&
                consumer.worker != null)
          consumer,
    ];
    if (subscribers.isEmpty) return const DecisionOutcome.allow();
    final request = DecisionRequest(
      id: contract.id,
      data: data,
      budgetMillis: budget.inMilliseconds,
    ).toJson();
    final outcomes = await Future.wait(
      subscribers.map((consumer) async {
        try {
          final response = DecisionResponse.fromJson(
            await consumer.worker!.channel.request(
              IpcMethod.eventDecide,
              request,
              budget,
            ),
          );
          return response.isDeny
              ? DecisionOutcome.deny(
                  response.reason ?? 'denied by "${consumer.id}"',
                )
              : const DecisionOutcome.allow();
        } on IpcException catch (e) {
          if (e.code == IpcErrorCode.timeout) {
            _log.warn(
              '[${consumer.id}] no verdict on "${contract.id}" within ${budget.inMilliseconds} ms',
            );
            return DecisionOutcome.timeout(contract.delivery.onTimeout);
          }
          _log.warn(
            '[${consumer.id}] decision on "${contract.id}" failed: ${e.error}',
          );
          return DecisionOutcome.timeout(contract.delivery.onTimeout);
        }
      }),
    );
    return outcomes.firstWhere(
      (o) => !o.allowed,
      orElse: () => const DecisionOutcome.allow(),
    );
  }

  void dispose() {
    for (final outbox in _outboxes.values) {
      outbox.close();
    }
    _outboxes.clear();
  }
}

/// How one internal primitive is queued for a worker.
///
/// `core.player.position` keeps the newest pending update per entity. Session
/// join, leave, and every other primitive keep each occurrence.
DeliverySpec primitiveDeliverySpec(
  String primitiveId, {
  required int queueLimit,
}) {
  if (primitiveId == 'core.player.position') {
    return DeliverySpec(
      overflow: OverflowPolicy.coalesce,
      coalesceKey: 'entityId',
      queueLimit: queueLimit,
    );
  }
  return DeliverySpec(queueLimit: queueLimit);
}

/// The core's only way to reach event packs: observational primitives are
/// forwarded demand-driven and batched; decision primitives are put to the
/// packs that registered a decision handler, each within a budget.
final class PrimitiveBus {
  PrimitiveBus({
    required this.registry,
    required this.dispatcher,
    required this.options,
    required Logger log,
    required PluginInstance? Function(String id) lookup,
  }) : _log = log,
       _lookup = lookup;

  final ContractRegistry registry;
  final EventDispatcher dispatcher;
  final PluginRuntimeOptions options;
  final Logger _log;
  final PluginInstance? Function(String id) _lookup;
  final Map<String, WorkerOutbox> _outboxes = {};

  int forwarded = 0;
  int skippedNoDemand = 0;

  void attach(PluginInstance pack) {
    final worker = pack.worker;
    if (worker == null) return;
    _outboxes[pack.id]?.close();
    _outboxes[pack.id] = WorkerOutbox(
      send: (method, params) => worker.channel.notify(method, params),
      singleMethod: IpcMethod.primitive,
      batchMethod: IpcMethod.primitiveBatch,
      maxBatchItems: options.maxBatchItems,
      onGap: (type, dropped) {
        pack.droppedEvents += dropped;
        _log.warn(
          '[${pack.id}] dropped $dropped primitive(s) of "$type" (queue full)',
        );
      },
    );
  }

  void detach(String packId) => _outboxes.remove(packId)?.close();

  /// Cheap pre-check so the core can skip building payloads nobody wants.
  bool hasObservers(String primitiveId) => registry
      .primitiveSubscribers(primitiveId)
      .any((pack) => registry.hasDemand(pack, primitiveId));

  bool hasDeciders(String primitiveId) => registry
      .primitiveSubscribers(primitiveId)
      .any((pack) => registry.decisionContractFor(pack, primitiveId) != null);

  /// Forwards an observation to every subscribed pack that currently has
  /// downstream demand for it.
  void observe(String primitiveId, Map<String, Object?> data) {
    final packs = registry.primitiveSubscribers(primitiveId);
    if (packs.isEmpty) return;
    Map<String, Object?>? envelope;
    for (final packId in packs) {
      if (!registry.hasDemand(packId, primitiveId)) {
        skippedNoDemand++;
        continue;
      }
      final outbox = _outboxes[packId];
      final pack = _lookup(packId);
      if (outbox == null || pack == null || pack.state != PluginState.active) {
        continue;
      }
      envelope ??= PrimitiveEnvelope(
        id: primitiveId,
        data: data,
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
      ).toJson();
      outbox.enqueue(
        primitiveId,
        primitiveDeliverySpec(
          primitiveId,
          queueLimit: options.primitiveQueueLimit,
        ),
        envelope,
      );
      forwarded++;
    }
  }

  /// Puts a decision primitive to each pack with a decision contract fed by
  /// it, sequentially; the first deny ends the round. A pack may veto or
  /// allow directly, or translate the primitive into a contract event that
  /// its consumers judge within the remaining budget.
  Future<DecisionOutcome> decide(
    String primitiveId,
    Map<String, Object?> data,
  ) async {
    for (final packId in List.of(registry.primitiveSubscribers(primitiveId))) {
      final contract = registry.decisionContractFor(packId, primitiveId);
      final pack = _lookup(packId);
      if (contract == null ||
          pack == null ||
          pack.state != PluginState.active ||
          pack.worker == null) {
        continue;
      }
      final budget = contract.delivery.budget;
      final deadline = DateTime.now().add(budget);
      final DecisionResponse response;
      try {
        response = DecisionResponse.fromJson(
          await pack.worker!.channel.request(
            IpcMethod.primitiveDecide,
            DecisionRequest(
              id: primitiveId,
              data: data,
              budgetMillis: budget.inMilliseconds,
            ).toJson(),
            budget,
          ),
        );
      } on IpcException catch (e) {
        _log.warn(
          '[$packId] decision primitive "$primitiveId" failed: ${e.error}; applying ${contract.delivery.onTimeout.name}',
        );
        final outcome = DecisionOutcome.timeout(contract.delivery.onTimeout);
        if (!outcome.allowed) return outcome;
        continue;
      }
      if (response.verdict != null) {
        if (response.isDeny) {
          return DecisionOutcome.deny(response.reason ?? 'denied by "$packId"');
        }
        continue;
      }
      if (response.contract != contract.id) {
        _log.warn(
          '[$packId] translated "$primitiveId" into "${response.contract}", which is not its decision contract; ignored',
        );
        continue;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        final outcome = DecisionOutcome.timeout(contract.delivery.onTimeout);
        if (!outcome.allowed) return outcome;
        continue;
      }
      final outcome = await dispatcher.decide(
        contract,
        response.data!,
        remaining,
      );
      if (!outcome.allowed) return outcome;
    }
    return const DecisionOutcome.allow();
  }

  void dispose() {
    for (final outbox in _outboxes.values) {
      outbox.close();
    }
    _outboxes.clear();
  }
}
