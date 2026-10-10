enum PluginHostErrorCode {
  runtimeUnavailable,
  notInstalled,
  alreadyInstalled,
  incompatible,
  dependency,
  invalidState,
  startFailed,
  stopFailed,
  updateFailed,
  commandNotFound,
  commandFailed,
  configInvalid,

  /// An event pack would provide a contract another active pack provides.
  conflict,

  /// Required event contracts have no compatible active provider.
  contractUnavailable,
}

/// Failure of a host operation. [details] carries actionable specifics such
/// as the missing dependencies or the worker's stderr tail.
final class PluginHostException implements Exception {
  const PluginHostException(this.code, this.message, {this.details = const []});

  final PluginHostErrorCode code;
  final String message;
  final List<String> details;

  @override
  String toString() {
    if (details.isEmpty) return 'PluginHostException(${code.name}): $message';
    return 'PluginHostException(${code.name}): $message\n  ${details.join('\n  ')}';
  }
}
