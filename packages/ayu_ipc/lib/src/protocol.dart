/// Protocol-level constants shared by both ends of the channel.
abstract final class IpcProtocol {
  /// Current wire protocol version.
  static const version = 1;

  /// Versions this implementation can speak, newest first.
  static const supportedVersions = <int>[1];

  /// Version of the public plugin API contract. Manifests constrain against
  /// this value through their `api` field.
  static const apiVersion = '1.0.0';

  /// Picks the highest version both sides support, or `null`.
  static int? negotiate(Iterable<int> peerVersions) {
    for (final candidate in supportedVersions) {
      if (peerVersions.contains(candidate)) return candidate;
    }
    return null;
  }
}

/// Method names. Direction is documented per constant.
abstract final class IpcMethod {
  // worker -> host
  static const hello = 'hello';
  static const log = 'log';
  static const commandRegister = 'command.register';
  static const commandUnregister = 'command.unregister';
  static const eventSubscribe = 'event.subscribe';
  static const eventUnsubscribe = 'event.unsubscribe';
  static const configGet = 'config.get';

  // host -> worker
  static const init = 'init';
  static const shutdown = 'shutdown';
  static const ping = 'ping';
  static const event = 'event';
  static const commandExecute = 'command.execute';
}

/// Capability identifiers a plugin may declare in its manifest. The host
/// refuses requests whose capability was not declared.
abstract final class PluginCapability {
  static const commands = 'commands';
  static const events = 'events';
  static const config = 'config';

  static const all = <String>{commands, events, config};
}

/// Log levels accepted on the wire.
abstract final class IpcLogLevel {
  static const debug = 'debug';
  static const info = 'info';
  static const warn = 'warn';
  static const error = 'error';

  static const all = <String>{debug, info, warn, error};
}

/// Tunables of a [FrameChannel]. Defaults are conservative and apply to
/// both the host and the worker side.
final class ChannelOptions {
  const ChannelOptions({
    this.maxFrameBytes = 1 << 20,
    this.defaultRequestTimeout = const Duration(seconds: 5),
    this.maxPendingRequests = 256,
    this.maxInFlightInbound = 256,
    this.outboundHighWatermarkBytes = 4 << 20,
  });

  /// Largest `kind + id + payload` accepted or produced.
  final int maxFrameBytes;

  final Duration defaultRequestTimeout;

  /// Outgoing requests awaiting a response.
  final int maxPendingRequests;

  /// Incoming requests being handled concurrently.
  final int maxInFlightInbound;

  /// Above this many unflushed bytes, notifications are dropped instead of
  /// queued. Requests are never dropped; they are bounded by
  /// [maxPendingRequests].
  final int outboundHighWatermarkBytes;
}
